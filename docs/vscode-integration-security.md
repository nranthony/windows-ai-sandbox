# VS Code Dev Container Integration — Security Findings

Distilled from a macolima-origin audit. These findings are platform-independent
(VS Code Dev Containers behavior, not macOS/WSL-specific). All apply to this
repo's rootless Docker + container-root setup.

This repo is entered **only** via *Attach to Running Container* — there is no
`.devcontainer/` and no "Reopen in Container" flow. The findings below are about
what VS Code injects at **attach** time and how host-side config closes it.

---

## Anatomy: where VS Code config lives

On attach, VS Code connects to the container `scripts/profile.sh <profile> up`
already started — it does **not** read any repo `devcontainer.json` (verified
against the official Dev Containers docs). The config VS Code *does* read on
attach comes from two host-side places:

| Source | Consumed by | Holds |
|---|---|---|
| Host user `settings.json` | VS Code (host) | `remote.SSH.*` + `dev.containers.*` security keys; `dev.containers.defaultExtensions` |
| Attached-container config (`Dev Containers: Open Attached Container Configuration File`, keyed by image) | VS Code Server (in-container) | `forwardPorts`, `settings`, `extensions`, `remoteUser` — the per-container UX/guardrail layer (lands in `/root/.vscode-server/`, NOT baked into the image) |

**None of the security posture lives in VS Code config** — it lives in
`docker-compose.yml` + `seccomp.json` + the image. A CLI-only user
(`scripts/profile.sh attach`) gets the identical hardened container, minus the
`~/.vscode-server` tree.

### The one flow: Attach to Running Container

`scripts/profile.sh <profile> up`, then command palette → *Dev Containers: Attach
to Running Container...* → `ai-sandbox-<profile>`. Because attach ignores any
repo `devcontainer.json`, the predictability guardrails the old Reopen path baked
in — `remote.autoForwardPorts: false`, explicit `forwardPorts`, pinned
interpreter/terminal — are restored via the **attached-container configuration
file** instead (below). They are UX guardrails, not sandbox controls; the
container is equally hardened without them.

### Extensions and the port guardrail

- **Extensions:** host user `settings.json` → `"dev.containers.defaultExtensions": [...]` (marketplace `publisher.extension` IDs). Installs into *any* attached container, on next attach, into `/root/.vscode-server/extensions/` — no image rebuild.
- **Port guardrail + interpreter/terminal:** `Dev Containers: Open Attached Container Configuration File` (pick the `windows-ai-sandbox` image), then set `forwardPorts: [8080, 8501, 8188]` and `settings: { "remote.autoForwardPorts": false, ... }`. `autoForwardPorts: false` matters on Windows — a service binding `0.0.0.0` otherwise surfaces on Windows localhost without being declared.

---

## Findings

### A — VS Code forwards host SSH agent into the container

`SSH_AUTH_SOCK=/tmp/vscode-ssh-auth-*.sock` appears inside the container. Any
process can `ssh` to any host whose keys are in the user's host `ssh-agent`.

**Why it matters:** The egress proxy is HTTP/S only (Squid). The firewall blocks
direct TCP. Neither control sees SSH traffic routed through the forwarded unix
socket — the socket itself is the bypass. The container's network identity is
sandboxed; its SSH identity is the host user's.

**Fix:** The primary defense is **in-container**, since attach reads no
`remoteEnv` to empty the socket: `config/.zshrc` runs `unset SSH_AUTH_SOCK` on
every shell and the Dockerfile purges `openssh-client` (no `ssh` client to use a
forwarded socket). The host setting `remote.SSH.enableAgentForwarding: false`
only governs the Remote-SSH extension, not Dev Containers' attach injection —
keep it set, but do not rely on it alone.

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

**Fix:** Under rootless Docker (container UID 0 = host UID 1000) the orphan's
blast radius is already bounded to ephemeral overlay state, so this is a tidiness
issue, not a containment boundary. Where you want it suppressed, set
`remoteUser` / `updateRemoteUserUID: false` in the **attached-container
configuration file** (the attach-mode equivalent of the old repo
`devcontainer.json` keys). Compose's `command: ["sleep", "infinity"]` already
holds PID 1 and attach does not override it.

---

## Required host VS Code settings

```jsonc
{
  "remote.SSH.enableAgentForwarding": false,                  // Finding A (in-container .zshrc unset is primary)
  "dev.containers.copyGitConfig": false,                      // Finding B
  "dev.containers.gitCredentialHelperConfigLocation": "none"  // Finding C — stops attach re-injecting the helper
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
| Re-introduce a repo `.devcontainer/devcontainer.json` to get "Reopen in Container" back | Reopen makes VS Code drive `docker compose up` itself — it needs `.env` plumbing (`PROFILE`/`COMPOSE_PROJECT_NAME`) and can spin up a second `172.30.0.0/24` network that collides with the running profile. Attach to the already-hardened `ai-sandbox-<profile>` instead. |
