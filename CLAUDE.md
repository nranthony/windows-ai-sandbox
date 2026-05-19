# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Secure Windows AI development environment. WSL2 Ubuntu 24.04 LTS + rootless Docker + NVIDIA CUDA, using a **profile-based pattern** (one shared image, many per-profile workspaces) adapted from the sibling `macolima` repo. Each profile gets its own container, its own persistent auth/config, its own Squid-gated egress.

## Architecture

```
Windows OS
  └─ WSL2 Ubuntu 24.04
      └─ rootless Docker (userns=host; container UID 0 ↔ host UID 1000)
          ├─ windows-ai-sandbox:latest   (shared image: CUDA + claude + gemini + gh + glab + uv + zsh)
          └─ per profile:
              ├─ ai-sandbox-<profile>    (agent; /workspace = ~/repo/<profile>/)
              ├─ egress-proxy-<profile>  (Squid; domain allowlist only way out)
              ├─ postgres-<profile>      (opt-in via COMPOSE_PROFILES=db-postgres)
              └─ mongo-<profile>         (opt-in via COMPOSE_PROFILES=db-mongo)
```

**Network model (load-bearing — see `sandbox-hardening-package.md` §4):**
- `sandbox-internal` (internal: true, IPAM 172.30.0.0/24) — agent-only, no direct internet
- `sandbox-external` — Squid's outbound side
- DNS sinkholed (`dns: [127.0.0.1]`) on the agent; internal names resolved via `extra_hosts` with static IPs. Closes the DNS-exfil side channel that `internal: true` alone does NOT close. See `docs/compose-network-ipam.md`.
- Removing `internal: true` turns the proxy into a suggestion.

**Per-profile state layout** (outlives container recreates):
```
~/.ai-sandbox/profiles/<profile>/
├── claude-home/       → /root/.claude           (sessions, settings, credentials, MCP)
├── claude.json        → /root/.claude.json      (single-file bind; seeded '{}' on first up)
├── cache/             → /root/.cache            (npm, uv, pip caches)
├── config/            → /root/.config
│   ├── gh/                                      (gh tokens)
│   ├── glab-cli/                                (glab tokens)
│   └── git/config                               (via GIT_CONFIG_GLOBAL)
├── gemini-home/       → /root/.gemini           (Gemini CLI oauth, settings, MCP)
└── db.env             (optional; postgres/mongo credentials — see config/db.env.template)
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
scripts/profile.sh <profile> auth-gemini        # gemini CLI OAuth login

# Day-to-day
scripts/profile.sh <profile> attach             # get back in
scripts/profile.sh <profile> down               # stop (state preserved)
scripts/profile.sh list                         # all profiles + up/down status

# Image rebuilds
scripts/profile.sh build                        # rebuild shared image (all profiles pick up)
scripts/profile.sh <profile> rebuild            # rebuild + recreate this profile
scripts/profile.sh <profile> rebuild --expose-dev  # also layer LAN port publishing

# State hygiene
scripts/profile.sh <profile> clean              # prune rotating state (paste-cache, backups)
scripts/profile.sh <profile> clean --deep       # also drop MCP logs + settings.json backups
scripts/profile.sh <profile> reset-settings     # re-seed claude settings.json from template
scripts/profile.sh <profile> reset-skills       # re-seed skills from config/skills/
scripts/profile.sh <profile> wipe               # blank-slate profile, keep auth
scripts/profile.sh <profile> wipe --dry-run     # show what would be wiped
scripts/profile.sh <profile> wipe --all-volumes # also drop DB named volumes

# Database (opt-in via COMPOSE_PROFILES=db-postgres or db-mongo or db-all)
COMPOSE_PROFILES=db-postgres scripts/profile.sh <profile> up
scripts/profile.sh <profile> db-reset           # wipe postgres volume, fresh initdb
```

### Temporarily widen egress for installs
```bash
# Uncomments the matching [tag] block in proxy/allowed_domains.txt, hot-reloads
# Squid, runs the command, restores the allowlist verbatim. flock-serialised.
scripts/with-egress.sh <profile> --with playwright-install -- \
  'cd /workspace/foo && playwright install chromium'

# Multiple sections:
scripts/with-egress.sh <profile> --with pypi,npm -- \
  'cd /workspace/foo && npm install && uv pip install -e ".[dev]"'

# Default --with is `pypi`. Sections live under PLANNING-MODE in
# proxy/allowed_domains.txt; PROJECT-PERSISTENT sections (already open by
# default) accept --with too but it's a no-op.
```

### Ephemeral one-shot container
```bash
# Disposable --rm container with the same hardening, attached to the running
# profile's sandbox-internal. Profile stack must already be up.
scripts/run-ephemeral.sh <profile>          # zsh shell
scripts/run-ephemeral.sh <profile> claude   # one-shot claude run
scripts/run-ephemeral.sh <profile> bash -c 'uv run python -c "import torch; print(torch.cuda.is_available())"'
```

### Testing GPU/CUDA
```bash
scripts/profile.sh <profile> exec bash -lc '
  cd /workspace/windows-ai-sandbox/container_testing && uv sync && \
  uv run python -c "import torch; print(torch.cuda.is_available())"
'
```

### Hardening Verification — three tiers

| Tier | Cost | What | When |
|---|---|---|---|
| 1 | ~3s | `scripts/profile.sh <p> verify` — fast tripwire, ~20 pass/fail checks | every `up` |
| 2 | ~10s | `scripts/profile.sh <p> audit` — ~80 structured probes, JSON to `~/.ai-sandbox/profiles/<p>/claude-home/audits/` | on demand or post config change |
| 3 | ~5k toks | agent reads JSON + staged SKILL.md, writes report.md next to the JSON (judgment only — no probe execution) | on demand |

```bash
# Tier 1 — tripwire (streams scripts/verify-sandbox.sh into container via stdin).
scripts/profile.sh <profile> verify
# Expected: uid_map "0 1000 1", CapEff=0, NoNewPrivs=1, Seccomp=2,
# direct internet blocked, api.anthropic.com reachable via proxy,
# example.com blocked, ssh/socat/bwrap absent, deny-destructive hook present.

# Tier 2 — structured audit (stages config to /workspace/temp_audit_package/
# then runs ~80 probes, saves JSON to host).
scripts/profile.sh <profile> audit
scripts/profile.sh <profile> audit --stage-only   # just stage, don't run
scripts/profile.sh <profile> audit --clean        # remove staged package

# Tier 3 — inside an attached agent session. Tier 2 must be run first.
# The SKILL.md is staged at /workspace/temp_audit_package/skills/audit-sandbox/
# and instructs the agent to read the JSON, cross-reference the staged
# CLAUDE.md, and write a report.md next to the JSON. No probe execution —
# judgment only.
```

### Image CVE Scan (trivy on host)
```bash
scripts/trivy-scan.sh         # config + secret + image (default)
scripts/trivy-scan.sh image   # CVE scan of windows-ai-sandbox:latest only
# Accepted CVEs: .trivyignore.yaml (each entry carries expired_at for re-check)
```

## Key Files and Configuration

### Top-level
- `Dockerfile` — shared image. CUDA 12.6.3 base (pinned by digest). Ships claude + gemini + gh + glab + uv + mongosh + zsh. Node.js 24. Playwright Chromium runtime libs baked in. Gitstatusd pre-installed. `bubblewrap` / `socat` / `openssh-client` deliberately NOT installed (see `sandbox-hardening-package.md` §7).
- `docker-compose.yml` — parameterized by `$PROFILE`. `sandbox-internal` (internal:true, IPAM 172.30.0.0/24, DNS sinkhole) + `sandbox-external` bridge. Squid sidecar. Optional postgres/mongo siblings via `COMPOSE_PROFILES`. cap_drop:ALL + seccomp + no-new-privileges, tmpfs noexec. `restart: "no"` (explicit `up` required after host reboot).
- `seccomp.json` — ported verbatim from macolima. `clone3 → ENOSYS`, `unshare(CLONE_NEWUSER)` blocked, full xattr family allowed.
- `proxy/squid.conf` + `proxy/allowed_domains.txt` — ML-tuned allowlist (Anthropic, Gemini, GitHub, GitLab, PyPI, PyTorch, NVIDIA, Ubuntu apt). Pinned subdomains (no parent wildcards per audit M3). Hot-reload: `docker exec egress-proxy-<p> squid -k reconfigure`.
- `config/.zshrc`, `config/.p10k.zsh` — baked into image at build.
- `config/claude-settings.json` — **restricts Claude's Bash/Read tools only** (not the shell). `defaultMode: auto`. Denies `pip install`, `uv add`, `curl`, `git push/fetch/config/submodule`, `awk`, `sed`, secrets reads. User shells are unrestricted — install deps at the CLI, then hand off to Claude.
- `config/db.env.template` — template for postgres/mongo credentials. Copy to profile's `db.env` and fill in.
- `.trivyignore.yaml` — CVE/misconfig accepts. Each entry has `expired_at` so it re-surfaces on re-scan.
- `sandbox-hardening-package.md` — ported audit doc; keep in sync with macolima.
- `docs/_archive/claude_internal_audit_wsl.md` — manual audit prompt (superseded by tier-2 probes + tier-3 skill; kept for reference).

### Scripts
- `scripts/profile.sh` — lifecycle driver. All commands live here (`up`, `down`, `attach`, `auth`, `auth-gemini`, `verify`, `audit`, `rebuild`, `clean`, `wipe`, `db-reset`, `reset-skills`, etc.).
- `scripts/init-profile-state.sh` — idempotent state bootstrap. Seeds `claude.json='{}'`, `claude-home/settings.json` from template, scrubs VS Code-injected `credential.helper` on every `up`.
- `scripts/setup.sh` — optional onboarding wrapper (brings up + seeds git user from `.env`).
- `scripts/verify-sandbox.sh` — tier-1 in-container tripwire. Runs the full hardening check.
- `scripts/audit/` — tier-2 structured audit (8 stdlib-Python probes + aggregate.py + audit.sh). See `scripts/audit/README.md`.
- `scripts/stage-audit-package.sh` — copies sandbox config + audit infrastructure into the profile workspace so probes can read seccomp.json / squid.conf / etc. from `/workspace/temp_audit_package/`.
- `scripts/with-egress.sh` — temporarily widen the allowlist for one command (uncomments `[tag]` blocks in `proxy/allowed_domains.txt`, hot-reloads Squid via `squid -k reconfigure`, restores verbatim on exit). flock-serialised + drift sentinel.
- `scripts/run-ephemeral.sh` — spawn a disposable `--rm` container attached to the running profile's `sandbox-internal` network. Same hardening as the persistent agent; everything outside bind mounts is discarded on exit.
- `scripts/trivy-scan.sh` — host-side image/config/secret scan. Requires trivy installed.
- `config/hooks/deny-destructive.sh` — PreToolUse hook closing the deny-list bypass class (find -delete, dd of=, etc.). See `docs/deny-destructive-hook-plan.md`.
- `config/skills/audit-sandbox/SKILL.md` — tier-3 agent-side skill for judgment over the audit JSON.

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
| Resources | `pids_limit: 512`, `mem_limit: 8g`, `cpus: 4` |
| Filesystem | rootfs rw (non-root userns + cap_drop is the boundary); `/tmp` + `/run` + `/root/.{npm-global,local}` tmpfs with `noexec,nosuid,nodev` |
| Network | `sandbox-internal` (internal:true, IPAM 172.30.0.0/24) + Squid sidecar on `sandbox-external` — allowlist is the only way out |
| DNS | Sinkholed (`dns: [127.0.0.1]`) + `extra_hosts` for internal names — closes DNS exfil channel |
| Agent tools | `claude settings.json` (defaultMode: auto) denies `curl/wget/ssh/scp/socat/nc/telnet`, `git push/clone/fetch/config/submodule`, `awk/sed`, `pip install`, `uv add`, secrets reads |
| Restart policy | `restart: "no"` — explicit `up` required after host reboot (prevents silent config-drift recovery) |

## File Structure

```
├── Dockerfile                    # Shared image (CUDA + claude + gemini + gh + glab + uv + mongosh + zsh)
├── docker-compose.yml            # Parameterized by $PROFILE; optional postgres/mongo via COMPOSE_PROFILES
├── seccomp.json                  # Syscall filter
├── .trivyignore.yaml             # Accepted CVEs/misconfigs with expiries
├── config/                       # Dotfiles + claude-settings.json + db.env.template + hooks + skills
├── proxy/                        # Squid.conf + allowed_domains.txt
├── scripts/                      # profile.sh, init-profile-state.sh, with-egress.sh, verify-sandbox.sh, audit/, trivy-scan.sh
├── docs/                         # Design notes, permissions model, seccomp/squid internals, debug recipes
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
