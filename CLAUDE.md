# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Secure Windows AI development environment. WSL2 Ubuntu 24.04 LTS + rootless Docker + NVIDIA CUDA, using a **profile-based pattern** (one shared image, many per-profile workspaces) adapted from the sibling `macolima` repo. Each profile gets its own container, its own persistent auth/config, its own Squid-gated egress.

## Architecture

```
Windows OS
  └─ WSL2 Ubuntu 24.04
      └─ rootless Docker (userns=host; container UID 0 ↔ host UID 1000)
          ├─ windows-ai-sandbox:latest   (shared image: CUDA + claude + gh + glab + uv + zsh)
          └─ per profile:
              ├─ ai-sandbox-<profile>    (agent; /workspace = ~/repo/<profile>/)
              └─ egress-proxy-<profile>  (Squid; domain allowlist only way out)
```

**Network model (load-bearing — see `sandbox-hardening-package.md` §4):**
- `sandbox-internal` (internal: true) — agent-only, no direct internet
- `sandbox-external` — Squid's outbound side
- Removing `internal: true` turns the proxy into a suggestion.

**Per-profile state layout** (outlives container recreates):
```
~/.ai-sandbox/profiles/<profile>/
├── claude-home/       → /root/.claude           (sessions, settings, credentials, MCP)
├── claude.json        → /root/.claude.json      (single-file bind; seeded '{}' on first up)
├── cache/             → /root/.cache            (npm, uv, pip caches)
└── config/            → /root/.config
    ├── gh/                                      (gh tokens)
    ├── glab-cli/                                (glab tokens)
    └── git/config                               (via GIT_CONFIG_GLOBAL)
```

## Common Development Tasks

### Initial Setup (Run Once)
```bash
cd host_setup
./setup-rootless-docker-wsl.sh         # Rootless Docker (uses sudo internally)
sudo ./wsl_conf_update.sh              # /etc/wsl.conf
./ohmyzsh-host-setup.sh                # Optional: host-side oh-my-zsh
```

### Profile Lifecycle
```bash
# First-time profile bring-up
mkdir -p ~/repo/<profile>                       # workspace dir (holds many repos)
scripts/profile.sh <profile> up                 # brings up agent + egress-proxy
scripts/profile.sh <profile> attach             # zsh into container
scripts/profile.sh <profile> auth               # claude login (one-time)
scripts/profile.sh <profile> auth-github        # gh auth login
scripts/profile.sh <profile> auth-gitlab        # glab auth login

# Day-to-day
scripts/profile.sh <profile> attach             # get back in
scripts/profile.sh <profile> down               # stop (state preserved)
scripts/profile.sh list                         # all profiles + up/down status

# Image rebuilds
scripts/profile.sh build                        # rebuild shared image (all profiles pick up)
scripts/profile.sh <profile> rebuild            # rebuild + recreate this profile

# State hygiene
scripts/profile.sh <profile> clean              # prune rotating state (paste-cache, backups)
scripts/profile.sh <profile> clean --deep       # also drop MCP logs + settings.json backups
scripts/profile.sh <profile> reset-settings     # re-seed claude settings.json from template
```

### Testing GPU/CUDA
```bash
scripts/profile.sh <profile> exec bash -lc '
  cd /workspace/windows-ai-sandbox/container_testing && uv sync && \
  uv run python -c "import torch; print(torch.cuda.is_available())"
'
```

### Hardening Verification
```bash
scripts/profile.sh <profile> exec bash /workspace/windows-ai-sandbox/scripts/verify-sandbox.sh
# Expected: uid_map "0 1000 1", CapEff=0, NoNewPrivs=1, Seccomp=2,
# direct internet blocked, api.anthropic.com reachable via proxy,
# example.com blocked, ssh/socat/bwrap absent.
```

### Image CVE Scan (trivy on host)
```bash
scripts/trivy-scan.sh         # config + secret + image (default)
scripts/trivy-scan.sh image   # CVE scan of windows-ai-sandbox:latest only
# Accepted CVEs: .trivyignore.yaml (each entry carries expired_at for re-check)
```

## Key Files and Configuration

### Top-level
- `Dockerfile` — shared image. CUDA 12.6.3 base (pinned by digest). Ships claude + gh + glab + uv + zsh. `bubblewrap` / `socat` / `openssh-client` deliberately NOT installed (see `sandbox-hardening-package.md` §7).
- `docker-compose.yml` — parameterized by `$PROFILE`. `sandbox-internal` internal:true + `sandbox-external` bridge, Squid sidecar, cap_drop:ALL + seccomp + no-new-privileges, tmpfs noexec.
- `seccomp.json` — ported verbatim from macolima. `clone3 → ENOSYS`, `unshare(CLONE_NEWUSER)` blocked, full xattr family allowed.
- `proxy/squid.conf` + `proxy/allowed_domains.txt` — ML-tuned allowlist (Anthropic, GitHub, GitLab, PyPI, PyTorch, NVIDIA, Ubuntu apt). Hot-reload after edits: `docker compose restart egress-proxy` under the profile's `COMPOSE_PROJECT_NAME`.
- `config/.zshrc`, `config/.p10k.zsh` — baked into image at build.
- `config/claude-settings.json` — **restricts Claude's Bash/Read tools only** (not the shell). Denies `pip install`, `uv add`, `curl`, `git push/fetch`, secrets reads. User shells are unrestricted — install deps at the CLI, then hand off to Claude.
- `.trivyignore.yaml` — CVE/misconfig accepts. Each entry has `expired_at` so it re-surfaces on re-scan.
- `sandbox-hardening-package.md` + `claude_internal_audit_macolima.md` — ported audit docs; keep in sync with macolima.

### Scripts
- `scripts/profile.sh` — lifecycle driver. All commands live here.
- `scripts/init-profile-state.sh` — idempotent state bootstrap. Seeds `claude.json='{}'`, `claude-home/settings.json` from template, scrubs VS Code-injected `credential.helper` on every `up`.
- `scripts/setup.sh` — optional onboarding wrapper (brings up + seeds git user from `.env`).
- `scripts/verify-sandbox.sh` — in-container tripwire. Runs the full hardening check.
- `scripts/trivy-scan.sh` — host-side image/config/secret scan. Requires trivy installed.

### Dev Container Integration
- `.devcontainer/devcontainer.json` — slim shim. Uses `dockerComposeFile` so VS Code and CLI share the profile container. Requires `PROFILE` exported before `code .`.
- `devcontainer-template/devcontainer.json` — drop-in template for any repo under `~/repo/<profile>/<repo>/`. Same `dockerComposeFile` pattern.

### Environment
- `.env` (repo root): `GIT_NAME="..."`, `GIT_EMAIL="..."`. Read by `scripts/setup.sh` host-side; not mounted in-container.

## Host VS Code Settings (IMPORTANT — audit Findings A + B)

Add to your host VS Code `settings.json`:
```jsonc
{
  "remote.SSH.enableAgentForwarding": false,   // Finding A — prevents SSH_AUTH_SOCK leaking into container
  "dev.containers.copyGitConfig": false        // Finding B — prevents host ~/.gitconfig being copied to container
}
```
Belt-and-braces: the Dockerfile also purges `openssh-client`, and `init-profile-state.sh` scrubs any `credential.helper` injected into the profile's `config/git/config` on every `up`.

## Security Posture

| Layer | Control |
|---|---|
| User namespace | Rootless Docker; container UID 0 maps to host UID 1000 (NOT root) |
| Syscalls | `seccomp=./seccomp.json` (mode 2) — `clone3→ENOSYS`, no user-namespace nesting |
| Capabilities | `cap_drop: ALL` — no NET_RAW, no SYS_ADMIN, etc. |
| Privilege escalation | `no-new-privileges:true` |
| Resources | `pids_limit: 512`, `mem_limit: 8g`, `cpus: 4`, `ulimits.nproc: 512` |
| Filesystem | rootfs rw (non-root userns + cap_drop is the boundary); `/tmp` + `/run` + `/root/.{npm-global,local}` tmpfs with `noexec,nosuid,nodev` |
| Network | `sandbox-internal` (internal:true) + Squid sidecar on `sandbox-external` — allowlist is the only way out |
| Agent tools | `claude settings.json` denies `curl/wget/ssh/scp/socat/nc/telnet`, `git push/clone/fetch`, `pip install`, `uv add`, secrets reads |

## File Structure

```
├── Dockerfile                    # Shared image (CUDA + claude + gh + glab + uv + zsh)
├── docker-compose.yml            # Parameterized by $PROFILE
├── seccomp.json                  # Syscall filter
├── .trivyignore.yaml             # Accepted CVEs/misconfigs with expiries
├── config/                       # Dotfiles + claude-settings.json template
├── proxy/                        # Squid.conf + allowed_domains.txt
├── scripts/                      # profile.sh, init-profile-state.sh, setup.sh, verify-sandbox.sh, trivy-scan.sh
├── .devcontainer/                # Slim VS Code shim (dockerComposeFile → ../docker-compose.yml)
├── devcontainer-template/        # Drop-in for per-repo dev containers
├── host_setup/                   # WSL Ubuntu rootless-Docker setup (run once)
├── container_testing/            # CUDA/PyTorch test environment (uv project)
├── archived_script_ref/          # Deprecated material
├── win_setup/                    # Windows .wslconfig
├── reports/                      # Docker-bench audit reports
└── images/                       # README screenshots
```

## Important Notes

- **Always `code .` from inside WSL Ubuntu**, never from Windows (rootful Docker takeover risk).
- Rootless Docker socket: `/run/user/1000/docker.sock`.
- Container runs as **root** — this is correct with rootless userns=host (container UID 0 = host UID 1000). Flipping to non-root inside would remap to host UID 100999 (nobody) and break workspace writes.
- **CUDA**: 12.6.3 (requires NVIDIA driver ≥530.30.02, tested with 566.36).
- **GPU passthrough**: `/dev/dxg` + `/usr/lib/wsl` volume + `LD_LIBRARY_PATH=/usr/lib/wsl/lib`. NOT `--gpus all` (broken under NVIDIA Container Toolkit ≥1.18).
- NVIDIA Container Toolkit pinned to `1.17.8-1` in `setup-rootless-docker-wsl.sh`.
- uv at `/usr/local/bin/uv`; default venv `/root/.venv` (Python 3.12).
- Forwarded ports: 8080, 8501, 8188.
- D-Bus race on WSL restart handled by kickstart block in `~/.zprofile`/`~/.profile` (from host setup).
