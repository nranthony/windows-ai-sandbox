from __future__ import annotations

import hashlib
import os
import subprocess

import docker


DOCKER_SOCK = os.environ.get(
    "DOCKER_HOST",
    f"unix:///run/user/{os.getuid()}/docker.sock",
)
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
PROFILE_SCRIPT = os.path.join(REPO_ROOT, "scripts", "profile.sh")
ALLOWLIST_PATH = os.path.join(REPO_ROOT, "proxy", "allowed_domains.txt")
CONTAINER_ALLOWLIST = "/etc/squid/allowed_domains.txt"


class DockerClient:
    def __init__(self) -> None:
        try:
            self.client = docker.DockerClient(base_url=DOCKER_SOCK)
            self.client.ping()
        except Exception:
            self.client = None

    def get_running_profiles(self) -> list[str]:
        if self.client is None:
            return []
        profiles = []
        for c in self.client.containers.list(filters={"status": "running"}):
            name = c.name
            if name.startswith("ai-sandbox-") and not name.startswith("ai-sandbox-egress"):
                profiles.append(name.removeprefix("ai-sandbox-"))
        return sorted(profiles)

    def reload_all_proxies(self) -> list[dict]:
        results = []
        for profile in self.get_running_profiles():
            results.append(self._reload_proxy(profile))
        return results

    def _reload_proxy(self, profile: str) -> dict:
        proxy_name = f"egress-proxy-{profile}"
        try:
            container = self.client.containers.get(proxy_name)
        except docker.errors.NotFound:
            return {"profile": profile, "ok": False,
                    "msg": f"{proxy_name} not found"}

        # Detect stale bind mount BEFORE trusting a reconfigure. An external
        # atomic-replace edit (sed -i, vim, git checkout, an editor's temp+
        # rename) gives the host file a new inode; the running container stays
        # pinned to the old one and keeps serving the pre-edit allowlist. The
        # in-container domain count can't catch this — the stale file is the
        # old *full* allowlist, so the count looks healthy. Compare a hash of
        # the host file against the container's copy instead.
        if self._allowlist_drifted(container):
            return {"profile": profile, "ok": False,
                    "msg": "Host allowlist differs from the container's copy "
                           "(stale bind mount — likely an external edit that "
                           "swapped the file's inode). Reconfigure would load "
                           "stale content. Recreate the proxy to resync.",
                    "needs_recreate": True}

        exit_code, _ = container.exec_run("squid -k reconfigure")
        if exit_code != 0:
            return {"profile": profile, "ok": False,
                    "msg": "squid -k reconfigure failed",
                    "needs_recreate": True}

        domains = self._count_active_domains(container)
        if domains == 0:
            return {"profile": profile, "ok": False,
                    "msg": "Reconfigure succeeded but 0 domains loaded — "
                           "likely stale bind mount. Recreate the proxy "
                           "container to resync.",
                    "needs_recreate": True}
        return {"profile": profile, "ok": True, "domains": domains}

    def _allowlist_drifted(self, container) -> bool:
        """True if the host allowlist and the container's copy differ.

        A byte-for-byte mismatch means the bind mount no longer points at the
        current host inode. Fails closed: if either side can't be read, treat
        it as drift so the caller routes to a recreate rather than trusting a
        stale reconfigure.
        """
        try:
            with open(ALLOWLIST_PATH, "rb") as f:
                host_hash = hashlib.sha256(f.read()).hexdigest()
        except OSError:
            return True
        exit_code, output = container.exec_run(f"cat {CONTAINER_ALLOWLIST}")
        if exit_code != 0 or output is None:
            return True
        return hashlib.sha256(output).hexdigest() != host_hash

    def _count_active_domains(self, container) -> int | None:
        exit_code, output = container.exec_run(
            "squid -k parse 2>&1", demux=False
        )
        # Fall back: count non-comment, non-blank lines in the allowlist
        exit_code2, raw = container.exec_run(
            "sh -c \"grep -cvE '^(#|$)' /etc/squid/allowed_domains.txt\"",
            demux=False,
        )
        try:
            return int(raw.decode().strip())
        except (ValueError, AttributeError):
            return None

    def recreate_proxy(self, profile: str) -> dict:
        # Recreate ONLY the proxy container, without disturbing the shared
        # project networks. This MUST go through scripts/profile.sh, not a raw
        # `docker compose` call, for two reasons:
        #
        #   1. Network wedge. A service-scoped `up --force-recreate
        #      egress-proxy` makes compose try to recreate sandbox-internal
        #      too; the still-running sandbox container pins an endpoint on it,
        #      the network removal fails mid-run, and the proxy is left
        #      half-attached (sandbox-external only) — a wedged state that
        #      blocks every later recreate.
        #   2. Missing profile env. Even a plain `up` from this process recreates
        #      the networks, because it lacks the SANDBOX_OCTET / compose-profiles
        #      / overlay env that profile.sh exports. Without SANDBOX_OCTET,
        #      compose computes a different expected subnet than the live
        #      172.30.<octet>.0/24 network, decides it is stale, and tears it
        #      down — same wedge as (1). profile.sh owns that env (golden rule 1).
        #
        # So: force-remove the proxy, then `profile.sh <profile> up`. profile.sh
        # runs a plain `up -d`, sees a matching network (correct octet), and
        # creates just the missing proxy on both networks, re-binding the
        # allowlist mount to the current host inode (the point of the resync).
        try:
            # Ignore failure: the container may already be absent.
            subprocess.run(
                ["docker", "rm", "-f", f"egress-proxy-{profile}"],
                capture_output=True, text=True,
            )
            r = subprocess.run(
                [PROFILE_SCRIPT, profile, "up"],
                capture_output=True, text=True,
            )
            if r.returncode == 0:
                return {"ok": True}
            return {"ok": False,
                    "msg": (r.stderr or r.stdout or "profile.sh up failed")}
        except OSError as e:
            return {"ok": False, "msg": str(e)}
