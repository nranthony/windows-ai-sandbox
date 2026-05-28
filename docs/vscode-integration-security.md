# VS Code Dev Container Integration — Security Findings

Distilled from a macolima-origin audit. These findings are platform-independent
(VS Code Dev Containers behavior, not macOS/WSL-specific). All apply to this
repo's rootless Docker + container-root setup.

---

## Anatomy: what lands where

`devcontainer.json` is a **host-side spec**, not a file that gets copied into
the container. The Dev Containers extension on Windows parses it, drives
`docker compose up` against the referenced compose file, then attaches VS Code
Server to the resulting container.

| Field | Consumed by | In-container artifact |
|---|---|---|
| `dockerComposeFile`, `service` | Dev Containers ext (host) | None — just selects which compose service to attach to |
| `workspaceFolder`, `forwardPorts`, `shutdownAction`, `name` | Dev Containers ext (host) | None |
| `remoteUser`, `containerUser`, `updateRemoteUserUID`, `overrideCommand` | Dev Containers ext (host) | None — they shape how attach behaves |
| `customizations.vscode.settings` | VS Code Server (in-container) | `/root/.vscode-server/data/Machine/settings.json` |
| `customizations.vscode.extensions` | VS Code Server (in-container) | `/root/.vscode-server/extensions/<ext>/` — downloaded on first attach, per-container, NOT baked into the image |

Consequence: **CLI-only users (`scripts/profile.sh attach`) get the same
hardened container minus the `~/.vscode-server` tree.** None of the security
posture lives in `devcontainer.json` — it lives in `docker-compose.yml` +
`seccomp.json` + the image.

### Two attach flows

| Flow | Reads devcontainer.json? | Hardening applied | What you lose with the other |
|---|---|---|---|
| **Reopen in Container** (`code .` in a folder with `.devcontainer/devcontainer.json`, then "Dev Containers: Reopen in Container") | Yes | Full compose hardening + `remote.autoForwardPorts: false` guardrail + explicit `forwardPorts` + pinned Python interpreter / zsh terminal | — |
| **Attach to Running Container** (command palette → pick `ai-sandbox-<profile>`) | No | Full compose hardening | No port-auto-forward guardrail (services binding `0.0.0.0` may surface on Windows localhost without declaration), manual port forwards, default interpreter/terminal |

Security delta between the two flows is **convenience, not safety** — both
attach to the same compose-hardened container. The Reopen flow's settings are
predictability/UX guardrails, not sandbox controls.

### Where to add extensions

Extensions are declared in the `customizations.vscode.extensions` array of
whichever devcontainer.json applies:

- **This repo** → `.devcontainer/devcontainer.json`
- **Any per-repo container under `~/repo/<profile>/<repo>/`** → that repo's `.devcontainer/devcontainer.json` (copy from `devcontainer-template/`)
- **The template itself** (so future drop-ins inherit) → `devcontainer-template/devcontainer.json`

Use marketplace IDs (`publisher.extension`). New extensions install on next
attach — no image rebuild needed, since they live in
`/root/.vscode-server/extensions/`.

**Escape hatch for the Attach-to-Running flow** (which ignores
devcontainer.json): in host VS Code user `settings.json`, set
`"dev.containers.defaultExtensions": [...]` — these install into *any*
container you attach to.

### Per-repo template requirements

**Compose path:** `devcontainer-template/devcontainer.json` uses
`../../windows-ai-sandbox/docker-compose.yml` as its compose path. This
**requires the sandbox repo to be cloned as a sibling at
`~/repo/<profile>/windows-ai-sandbox/`** — if your sandbox lives elsewhere
(e.g., `~/repo/sandbox/windows-ai-sandbox/`), edit the relative path or
symlink the sandbox repo into place.

**`.env` file:** The repo-root `.env` (next to `docker-compose.yml`) must
contain `PROFILE` and `COMPOSE_PROJECT_NAME`:
```
PROFILE=nranthony
COMPOSE_PROJECT_NAME=ai-sandbox-nranthony
```
VS Code's Dev Containers extension does **not** pass shell-session `export`s
through to docker compose — its `userEnvProbe` (default: `loginInteractiveShell`)
reads only the login shell environment, not per-session variables. Without
`PROFILE`, compose interpolation fails (`required variable PROFILE is missing`).
Without `COMPOSE_PROJECT_NAME`, VS Code derives the project name from the compose
file's directory (`windows-ai-sandbox`), which creates a second
`172.30.0.0/24` bridge network that collides with the already-running profile's
`ai-sandbox-<profile>_sandbox-internal`. `scripts/profile.sh` always exports its
own values, so the `.env` only affects the VS Code flow. Update these values when
switching profiles.

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
| "Reopen in Container" on a folder without a `.devcontainer/devcontainer.json` | VS Code will offer to generate one from a generic template — that container will NOT use this repo's hardened compose file. Either drop in `devcontainer-template/devcontainer.json` first, or use "Attach to Running Container" against the already-hardened `ai-sandbox-<profile>`. |
