from __future__ import annotations

import os
import subprocess

import docker


DOCKER_SOCK = os.environ.get(
    "DOCKER_HOST",
    f"unix:///run/user/{os.getuid()}/docker.sock",
)
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
COMPOSE_FILE = os.path.join(REPO_ROOT, "docker-compose.yml")


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
        try:
            env = os.environ.copy()
            env["PROFILE"] = profile
            env["COMPOSE_PROJECT_NAME"] = f"ai-sandbox-{profile}"
            subprocess.run(
                ["docker", "compose", "-f", COMPOSE_FILE,
                 "up", "-d", "--force-recreate", "egress-proxy"],
                env=env, capture_output=True, text=True, check=True,
            )
            return {"ok": True}
        except subprocess.CalledProcessError as e:
            return {"ok": False, "msg": e.stderr or str(e)}
