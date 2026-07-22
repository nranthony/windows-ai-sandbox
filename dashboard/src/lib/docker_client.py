from __future__ import annotations

import os
import subprocess

import docker


DOCKER_SOCK = os.environ.get(
    "DOCKER_HOST",
    f"unix:///run/user/{os.getuid()}/docker.sock",
)
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
PROFILE_SCRIPT = os.path.join(REPO_ROOT, "scripts", "profile.sh")


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

        # Guard: the caller derives profiles from running AGENT containers, so a
        # proxy that has exited (e.g. crashed, or an earlier reload killed it)
        # still reaches here. Any exec/restart on a stopped container raises a
        # 409 that would otherwise bubble up and crash the whole page. Report it
        # as a recoverable state and route to the recreate button instead.
        container.reload()  # refresh .status from the daemon
        if container.status != "running":
            return {"profile": profile, "ok": False,
                    "msg": f"{proxy_name} is {container.status}, not running — "
                           "recreate it to bring egress back.",
                    "needs_recreate": True}

        # Apply the host allowlist by RESTARTING the proxy — never
        # `squid -k reconfigure`. Two reasons, both load-bearing:
        #   1. SIGHUP death. squid runs as the container's foreground PID, so the
        #      SIGHUP that `reconfigure` sends is taken as Hangup and the proxy
        #      exits 129 — i.e. the "reload" KILLS the very container it targets,
        #      then the follow-up exec 409s on the corpse.
        #   2. Stale bind mount. An atomic-replace edit (this editor, sed -i,
        #      vim, git checkout) swaps the host file's inode; a live reconfigure
        #      would re-read the OLD inode the running container is still pinned
        #      to. A restart re-runs the entrypoint and re-resolves the mount to
        #      the current inode — which is exactly the resync we need, so it
        #      also subsumes the old _allowlist_drifted pre-check.
        try:
            container.restart(timeout=10)
            container.reload()
        except docker.errors.APIError as e:
            return {"profile": profile, "ok": False,
                    "msg": f"proxy restart failed: {e}",
                    "needs_recreate": True}

        if container.status != "running":
            return {"profile": profile, "ok": False,
                    "msg": "proxy did not come back up after restart — "
                           "check squid.conf / allowed_domains.txt.",
                    "needs_recreate": True}

        domains = self._count_active_domains(container)
        if not domains:
            return {"profile": profile, "ok": False,
                    "msg": "Proxy restarted but 0 domains loaded — check "
                           "allowed_domains.txt / squid.conf.",
                    "needs_recreate": True}
        return {"profile": profile, "ok": True, "domains": domains}

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
