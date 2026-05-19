# VS Code Dev Container Integration — Security Findings

Distilled from a macolima-origin audit. These findings are platform-independent
(VS Code Dev Containers behavior, not macOS/WSL-specific). All apply to this
repo's rootless Docker + container-root setup.

---

## Findings

### A — VS Code forwards host SSH agent into the container

`SSH_AUTH_SOCK=/tmp/vscode-ssh-auth-*.sock` appears inside the container. Any
process can `ssh` to any host whose keys are in the user's host `ssh-agent`.

**Why it matters:** The egress proxy is HTTP/S only (Squid). The firewall blocks
direct TCP. Neither control sees SSH traffic routed through the forwarded unix
socket — the socket itself is the bypass. The container's network identity is
sandboxed; its SSH identity is the host user's.

**Fix:** Host VS Code setting:
```json
"remote.SSH.enableAgentForwarding": false
```

Belt-and-braces: the Dockerfile also purges `openssh-client`, so even with a
forwarded socket the agent has no ssh client.

### B — VS Code copies host `~/.gitconfig` into container rootfs

A regular file (not a bind mount) appears on the overlay containing the host
user's git identity and OS-specific credential helpers. Git may not be using it
(we set `GIT_CONFIG_GLOBAL=/root/.config/git/config`), but it's readable and
becomes the silent fallback if `GIT_CONFIG_GLOBAL` is unset.

**Fix:** Host VS Code setting:
```json
"dev.containers.copyGitConfig": false
```

### C — VS Code injects a git credential helper that calls home

`.config/git/config` inside the container gets a `credential.helper` entry
pointing at a VS Code node shim. Any `git push`/`clone`/`fetch` invokes it,
which talks over a unix socket to the VS Code host process, which queries the
host credential manager. The container never sees the credential at rest, but
during the operation it has full access to whatever host creds exist — completely
bypassing the proxy allowlist.

**Fix — two layers:**

1. Host: `dev.containers.copyGitConfig: false` (Finding B) prevents initial injection.
2. Defensive: `init-profile-state.sh` strips any `credential.helper` from the
   profile's git config on every `up`, so the setting can't survive even if
   VS Code re-injects on attach.

### D — Orphaned UID-0 shell from VS Code attach

`ps` shows a `/bin/sh` process running as root, orphaned (PPid=0), spawned
during VS Code attach. Capabilities all zero, `NoNewPrivs=1`, `Seccomp=2` — it
inherits the sandbox posture. Under rootless Docker (container UID 0 = host
UID 1000) the blast radius is bounded to scribbling on ephemeral overlay state.

**Fix:** In workspace repos, add `.devcontainer/devcontainer.json` with:
```jsonc
{
  "updateRemoteUserUID": false,  // stops VS Code from usermod-ing inside the container
  "overrideCommand": false       // keeps compose command: ["sleep", "infinity"]
}
```

---

## Required host VS Code settings

```jsonc
{
  "remote.SSH.enableAgentForwarding": false,  // Finding A
  "dev.containers.copyGitConfig": false       // Findings B + C
}
```

---

## Operational guardrails

Things that look tempting but break the security model:

| Don't | Why |
|---|---|
| Re-enable Claude Code's `bwrap` sandbox | Needs unprivileged user namespaces, which seccomp blocks. The container is the boundary; bwrap is redundant. |
| Install `bubblewrap` or `socat` | bwrap was only for the disabled sandbox. socat is a raw-TCP exfil channel that bypasses Squid's HTTP-only egress. |
| Widen proxy allowlist to include `host.docker.internal` | That's the exact host↔container coupling the sandbox exists to prevent. |
| Bind-mount `~/.gitconfig` as a single file | `git config --global` writes via `rename()` atomically; single-file bind mounts return `EBUSY`. Use `GIT_CONFIG_GLOBAL` pointing into a directory bind mount instead. |
| Set `read_only: true` on the agent container | Breaks VS Code Dev Containers environment setup (`/etc/environment` writes). Security gain is zero — non-root userns + `cap_drop: ALL` is the boundary, not filesystem write access. |
