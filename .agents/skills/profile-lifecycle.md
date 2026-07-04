# Skill: Profile Lifecycle

`scripts/profile.sh` is the single entry point for everything below — never
call `docker compose` directly (it exports `PROFILE`/`COMPOSE_PROJECT_NAME`,
allocates the per-profile subnet octet, and layers compose overlays; bypassing
it breaks all three).

## First-time bring-up

```bash
mkdir -p ~/repo/<profile>                       # workspace dir (holds many repos)
scripts/profile.sh <profile> up                 # agent + egress-proxy
scripts/profile.sh <profile> attach             # zsh into container
scripts/profile.sh <profile> auth               # claude login (one-time)
scripts/profile.sh <profile> auth-github        # gh auth login
scripts/profile.sh <profile> auth-gitlab       # glab auth login
scripts/profile.sh <profile> auth-antigravity   # Antigravity (agy) console sign-in
```

## Day-to-day

```bash
scripts/profile.sh <profile> attach|down|logs|status
scripts/profile.sh list                         # all profiles + up/down status
scripts/profile.sh <profile> exec <cmd...>      # one-off command in the container
```

GPU: `up`/`recreate`/`rebuild` auto-layer `docker-compose.wsl-gpu.yml` when
`/dev/dxg` exists (WSL2). `SANDBOX_GPU=0` suppresses, `SANDBOX_GPU=1` forces.
Bare-Linux hosts need nothing — the base compose comes up GPU-less.

## Image builds

```bash
scripts/profile.sh build                        # rebuild shared image (all profiles)
scripts/profile.sh build --refresh-ai           # fast: bump Claude Code + agy (tail layer only)
scripts/profile.sh build --claude-version=1.2.3 # pin Claude Code (implies --refresh-ai)
scripts/profile.sh build --refresh-ai --recreate-running  # bump + roll running profiles
scripts/profile.sh recreate-all                 # force-recreate every RUNNING profile
scripts/profile.sh <profile> rebuild [--refresh-ai] [--expose-dev]
```

`--no-cache` / `--pull` are accepted by build/rebuild. `--expose-dev` layers
`docker-compose.<profile>.expose-dev.yml` (LAN port publishing — UNSAFE, may
drop network isolation).

## State hygiene

```bash
scripts/profile.sh <profile> clean              # prune rotating state
scripts/profile.sh <profile> clean --deep       # + MCP logs + settings backups
scripts/profile.sh <profile> reset-settings     # re-seed settings.json from sandbox_templates/claude/
scripts/profile.sh <profile> reset-skills       # re-seed skills from sandbox_templates/skills/
scripts/profile.sh <profile> wipe [--dry-run|--yes|--all-volumes]  # blank slate, KEEPS auth
```

`down` also age-prunes MCP logs + session transcripts older than
`SANDBOX_LOG_RETENTION_DAYS` (default 14).

## Databases (opt-in siblings)

```bash
COMPOSE_PROFILES=db-postgres scripts/profile.sh <profile> up    # or db-mongo / db-all
scripts/profile.sh <profile> db-reset           # wipe postgres volume, fresh initdb
```

Credentials: copy `sandbox_templates/common/db.env.template` to
`~/.ai-sandbox/profiles/<profile>/db.env` and fill in. The agent reaches them
at `postgres:5432` / `mongo:27017` (static IPs via extra_hosts).
NOTE: a plain `up` does NOT start the DB siblings — the `COMPOSE_PROFILES`
prefix is required every time.

## Ephemeral one-shot container

```bash
scripts/run-ephemeral.sh <profile> [command...]   # --rm container, same hardening,
                                                  # attached to the profile's sandbox-internal
```

Stack must already be up (borrows the running Squid). Everything outside bind
mounts is discarded on exit.

## GPU/CUDA smoke test

```bash
scripts/profile.sh <profile> exec bash -lc '
  cd /workspace/windows-ai-sandbox/container_testing && uv sync && \
  uv run python -c "import torch; print(torch.cuda.is_available())"
'
```

Expected: `True` on WSL2+GPU; `False` on bare-Linux hosts (correct, not a bug).

## `just` front door (optional)

Every recipe is a thin pass-through (`just up <p>` → `scripts/profile.sh <p> up`).
It holds NO logic and must never call `docker compose` directly. When adding or
renaming a profile.sh command, update the matching recipe and re-run `just --list`.
