# Custom Windows AI Sandbox
![tech stack logo](images/ai-sandbox-v02crop800px.png)

WSL2 Ubuntu 24.04 + rootless Docker + NVIDIA CUDA, organized as a **profile-based sandbox**: one shared hardened image, many per-profile workspaces, Squid-gated egress. Adapted from the sibling [macolima](https://github.com/nranthony/macolima) project.

#### Windows OS &#8594; WSL2 Ubuntu 24.04 LTS &#8594; Rootless Docker &#8594; `windows-ai-sandbox:latest` (one per profile)

---

## Quick Start

```bash
# One-time host setup (see "Initial Setup" below)
cd host_setup && ./setup-rootless-docker-wsl.sh && sudo ./wsl_conf_update.sh

# Build the shared image
scripts/profile.sh build

# Bring up a profile (workspace = ~/repo/<profile>/)
mkdir -p ~/repo/<profile>
scripts/profile.sh <profile> up
scripts/profile.sh <profile> auth           # claude login (one-time)
scripts/profile.sh <profile> auth-github    # optional
scripts/profile.sh <profile> attach         # zsh into the container
```

Day-to-day: `scripts/profile.sh <profile> {up,down,attach,logs,status,exec,clean}`. See `scripts/profile.sh list` for all profiles.

---

## What's inside

| Layer | Details |
|---|---|
| Base image | NVIDIA CUDA 12.6.3 on Ubuntu 24.04 (digest-pinned) |
| Tools baked in | Claude Code, GitHub CLI (`gh`), GitLab CLI (`glab`), `uv`, zsh + oh-my-zsh + powerlevel10k |
| Runtime hardening | `cap_drop: ALL`, `seccomp=./seccomp.json`, `no-new-privileges`, tmpfs noexec, resource limits (see `docker-compose.yml` / [ARCHITECTURE.md](ARCHITECTURE.md) — compose is the source of truth) |
| Network | `sandbox-internal` (internal:true) + Squid sidecar on `sandbox-external`; allowlist is the only way out |
| User | root-in-container (UID 0) — remaps to host UID 1000 under rootless Docker userns=host |
| GPU | WSL2 hosts only: `docker-compose.wsl-gpu.yml` overlay (`/dev/dxg` + `/usr/lib/wsl` bind + `LD_LIBRARY_PATH`, not `--gpus all`), auto-layered by `profile.sh` when `/dev/dxg` exists. Bare-Linux hosts come up GPU-less on the same base compose |
| Persistent state | `~/.ai-sandbox/profiles/<profile>/` — outlives container recreates |

**Not installed, by design** (see `sandbox-hardening-package.md` §7): `bubblewrap`, `socat`, `openssh-client`. These are the tools that would weaponize container escape or VS Code agent-forwarding leaks. See `scripts/verify-sandbox.sh` for the full tripwire.

---

## Initial Setup

### Windows side
1. Copy `win_setup/.wslconfig` → `C:\Users\<UserName>\.wslconfig` (enables Windows firewall integration).
2. Open WSL Ubuntu in a fresh terminal tab (not the one auto-launched by `pwsh` — it has known stdout quirks).

### WSL Ubuntu side
```bash
cd host_setup
./setup-rootless-docker-wsl.sh     # rootless Docker (sudo used internally — read first!)
sudo ./wsl_conf_update.sh          # /etc/wsl.conf
./ohmyzsh-host-setup.sh            # optional: host-side oh-my-zsh
exit                               # then `wsl --shutdown` in Powershell, wait 8s, reopen
```

### VS Code host settings (important — audit Findings A + B)
In Windows VS Code: `Ctrl+Shift+P` → **"Preferences: Open User Settings (JSON)"** (or edit `%APPDATA%\Code\User\settings.json` directly — from WSL that's `/mnt/c/Users/<user>/AppData/Roaming/Code/User/settings.json`). Add:
```jsonc
{
  "remote.SSH.enableAgentForwarding": false,
  "dev.containers.copyGitConfig": false
}
```
These prevent host SSH agent sockets and `~/.gitconfig` (including credential helpers) from leaking into the container. The image also purges `openssh-client` and `init-profile-state.sh` scrubs injected credential helpers on every `up`, as belt-and-braces.

### Repo root `.env`
```bash
GIT_NAME="your-name"
GIT_EMAIL="your-email@example.com"
```
`GIT_NAME`/`GIT_EMAIL` are used by `scripts/setup.sh` to seed git identity. `scripts/profile.sh` always exports its own `PROFILE`/`COMPOSE_PROJECT_NAME` for every compose call, so they are not needed in `.env`.

---

## Profile Workflow

### Bring up a profile
```bash
mkdir -p ~/repo/<profile>                # workspace parent (holds one or more repos)
scripts/profile.sh <profile> up          # creates state dirs, brings up agent + egress-proxy
scripts/profile.sh <profile> auth        # claude login — one-time; token persists in ~/.ai-sandbox/
```

### Commands
| Command | Action |
|---|---|
| `up` | brings up stack + seeds state dirs |
| `down` | stops container (state preserved) |
| `attach` | zsh into the agent container |
| `auth` / `auth-github` / `auth-gitlab` | interactive logins |
| `logs` / `status` | compose logs / ps |
| `build` | rebuild shared image (all profiles pick up) |
| `rebuild` | build + recreate this profile |
| `reset-settings` | overwrite claude settings.json from template (backs up old) |
| `clean` [`--deep`] | prune rotating state (backups, paste-cache, MCP logs) |
| `list` | all profiles with up/down status |
| `exec <cmd>` | run arbitrary command inside the container |

### Optional: `just` front door
A repo-root `justfile` provides a discoverable, shorter alias over `scripts/profile.sh` and `scripts/setup.sh`. It is a **convenience layer only** — every recipe is a thin pass-through (it never calls `docker compose` directly, so the scripts' `PROFILE`/`COMPOSE_PROJECT_NAME` exports and the compose `${PROFILE:?}` guard stay in force). The bash scripts remain canonical. Run `just` (or `just --list`) to see all recipes.

```bash
just up <profile>            # = scripts/profile.sh <profile> up
just attach <profile>        # = scripts/profile.sh <profile> attach   (primary entry — attach-only)
just verify <profile>        # = scripts/profile.sh <profile> verify   (tier-1 hardening tripwire)
just rebuild <profile>       # = scripts/profile.sh <profile> rebuild
just build                   # = scripts/profile.sh build              (no profile arg)
just setup <profile> --name "Your Name" --email you@x   # = scripts/setup.sh <profile> ...
just list                    # = scripts/profile.sh list
```

Profile is the first positional arg to every per-profile recipe (`list` and `build` take none). Requires `just` on the WSL host (`sudo apt install just`, or the static binary from github.com/casey/just). Skip it entirely if you prefer the scripts — they're identical in effect.

> Unlike the sibling `macolima` repo, there are **no `colima-*` recipes** (WSL2 *is* the VM), `verify` fronts `profile.sh verify` rather than `setup.sh --verify`, and `build` takes no profile arg. See `docs/sibling-repo-relationship.md`.

### Per-profile state
```
~/.ai-sandbox/profiles/<profile>/
├── claude-home/       # claude sessions, settings, credentials, MCP
├── claude.json        # first-run state, oauthAccount
├── cache/             # npm, uv, pip caches
└── config/            # gh tokens, glab tokens, git config
```

### Inside the container
- `claude`, `gh`, `glab`, `uv`, `python3`, `node` pre-installed.
- `/workspace` = `~/repo/<profile>/` (many repos).
- `/root/.venv` (Python 3.12) — VS Code's default interpreter for smoke tests.
- Claude's `Bash` tool is restricted by `sandbox_templates/claude/claude-settings.json` (pip/uv/git push/curl/ssh denied). The interactive zsh is NOT restricted — install deps yourself during planning, then hand off to the agent.

---

## VS Code

The sandbox is entered via **Attach to Running Container** — VS Code connects to
the container the CLI already brought up. There is no `.devcontainer/` and no
"Reopen in Container" flow: Reopen would drive `docker compose up` itself (needing
`.env` plumbing and bypassing `profile.sh`'s per-profile subnet allocation), and
Attach ignores a repo `devcontainer.json` anyway.

1. Bring the profile up: `scripts/profile.sh <profile> up`.
2. In VS Code: `Ctrl+Shift+P` → `Dev Containers: Attach to Running Container...` → `ai-sandbox-<profile>`.

All hardening (seccomp, cap_drop, sandbox-internal, DNS sinkhole) lives in
`docker-compose.yml`, so the attached container is fully hardened regardless of
VS Code config.

### Host-side config (the part attach *does* read)

Attach ignores any repo `devcontainer.json`. VS Code instead reads your **host
user `settings.json`** plus a per-container *attached-container configuration*
keyed by image. Configure these once:

**1. Required security settings** — host user `settings.json` (`Ctrl+Shift+P` → *Preferences: Open User Settings (JSON)*):
```jsonc
{
  "remote.SSH.enableAgentForwarding": false,                  // Finding A — SSH agent leak
  "dev.containers.copyGitConfig": false,                      // Finding B — host gitconfig copy
  "dev.containers.gitCredentialHelperConfigLocation": "none"  // Finding C — host credential helper
}
```

**2. Extensions** — host user `settings.json`. `defaultExtensions` installs into *any* attached container:
```jsonc
"dev.containers.defaultExtensions": [
  "ms-python.python",
  "ms-python.vscode-pylance",
  "ms-toolsai.jupyter",
  "ms-python.autopep8",
  "mhutchie.git-graph"
]
```

**3. Port guardrail + interpreter/terminal** — `Ctrl+Shift+P` → *Dev Containers: Open Attached Container Configuration File* (pick the `windows-ai-sandbox` image):
```jsonc
{
  "forwardPorts": [8080, 8501, 8188],
  "settings": {
    "remote.autoForwardPorts": false,
    "python.defaultInterpreterPath": "/root/.venv/bin/python",
    "terminal.integrated.defaultProfile.linux": "zsh"
  }
}
```
`autoForwardPorts: false` matters on Windows — a service binding `0.0.0.0`
otherwise surfaces on Windows localhost without being declared.

See [`docs/vscode-integration-security.md`](docs/vscode-integration-security.md) for the full findings and in-container defenses.

---

## Testing GPU/CUDA
```bash
scripts/profile.sh <profile> exec bash -lc '
  cd /workspace/windows-ai-sandbox/container_testing && uv sync && \
  uv run python -c "import torch; print(torch.cuda.is_available())"
'
# Expected: True
```
Or inside the attached container: `jupyter notebook container_testing/cuda_test.ipynb` — `CUDA available: True` in the first cell.

---

## Hardening Verification
```bash
scripts/profile.sh <profile> exec bash /workspace/windows-ai-sandbox/scripts/verify-sandbox.sh
```
Expected summary: direct internet blocked, `api.anthropic.com` reachable via proxy, `example.com` blocked, `CapEff=0`, `NoNewPrivs=1`, `Seccomp=2`, `bwrap/socat/ssh` absent, no leaked `/root/.gitconfig`, no `SSH_AUTH_SOCK`, no `credential.helper` injection.

## Image CVE Scan (trivy)
```bash
# On WSL host (see scripts/trivy-scan.sh header for install instructions)
scripts/trivy-scan.sh              # config + secret + image
scripts/trivy-scan.sh image        # CVE scan only
```
Accepted CVEs live in `.trivyignore.yaml`; each has an `expired_at` so it re-surfaces on re-scan.

---

## Troubleshooting

### Permission issues
See [`docs/sandbox-design-notes.md`](docs/sandbox-design-notes.md) — bind-mount ownership and why the container runs as root under rootless Docker (`sudo` is blocked by `no-new-privileges`). CUDA version matching is covered below.

### Common
- **Docker not starting on WSL resume**: `systemctl --user restart docker.service`. D-Bus race is kickstarted from `.zprofile`/`.profile` by the host setup.
- **CUDA version mismatch**: container uses 12.6.3 (driver ≥530.30).
- **VS Code `Exec format error` after Ubuntu upgrade**: `wsl --shutdown` in Powershell, reopen.
- **`code .` from Windows opens rootful Docker**: always launch from inside WSL.

### Uninstall rootless Docker
```bash
/usr/bin/dockerd-rootless-setuptool.sh uninstall -f
/usr/bin/rootlesskit rm -rf "$HOME/.local/share/docker"
```

---

## Docker Security Audit

Docker Bench results under `./reports/docker-bench-security-report.md`. Many rootful-Docker findings don't apply here (rootless daemon, user-namespaced); feedback on further hardening welcome.
```bash
git clone https://github.com/docker/docker-bench-security.git
cd docker-bench-security && ./docker-bench-security.sh
```

---

## Resources
- WSL config: https://learn.microsoft.com/en-us/windows/wsl/wsl-config
- CUDA on WSL: https://docs.nvidia.com/cuda/wsl-user-guide/
- Container breakout reading: https://unit42.paloaltonetworks.com/container-escape-techniques

![OhMyZsh inside the sandbox](images/zsh-in-ai-sandbox.png)
