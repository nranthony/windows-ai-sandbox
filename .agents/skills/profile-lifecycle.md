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

## Agent skills in a profile

Skills are **seeded per profile, never baked into the image** — the profile's
`claude-home` bind mount shadows `/root/.claude`, so anything `COPY`d there in
the `Dockerfile` is invisible at runtime.

Seeding **converges** ([ADR-0005](../../docs/adr/0005-skill-templates-are-source-of-truth.md)):
`sandbox_templates/skills/` is the source of truth and the profile's copy is a
derived cache, so every `up` reconciles it. A NEW or EDITED skill lands on the
next `up`; a skill REMOVED from the template is pruned. Restart `claude` in the
container to pick it up.

No backups are taken, and a divergent copy is replaced with a WARN naming it —
recover local edits from git, or make the edit in the template. A
`<name>.bak.<stamp>` inside `claude-home/skills/` would be a second LIVE copy of
the skill (for a skills-dir plugin the backup wins the name race), so stale ones
are pruned on sight. Directories the sandbox never seeded — e.g. `claude plugin
init` output — are reported and left alone.

`reset-skills` runs the same convergence without touching the container.

`sandbox_templates/skills/` mixes sandbox-native skills (this repo is their
source of truth) with material VENDORED through the depot channel —
`sandbox_templates/skills/UPSTREAM.md` says which is which. Edit a vendored
skill upstream, not here; the next vendor silently reverts local edits. Refresh
host-side, never during a build:

A vendored entry may be a loose skill or a **plugin** — a directory carrying
`.claude-plugin/plugin.json`, which loads as `<name>@skills-dir` with its own
skills namespaced (`/myconv:make-plan`, not `/make-plan`). The sync validates
each shape on its own terms and defaults to the plugin surface; upstream's loose
`templates/.claude/skills/` copies of `make-plan`/`wrap-up` are deliberately NOT
vendored, since the plugin supersedes them and carrying both re-creates the
duplicate-procedure drift. Check with `claude plugin list` inside the container.

```bash
just vendor-tools              # consume the channel: wheel, skills, plugin trees
just tools-check               # has the channel moved ahead of VENDORED.lock?
```

Channel path comes from `$DEPOT_DIR` or the gitignored `.depot-dir.local`; the
script writes only the template tree, so follow it with `reset-skills` per
profile to push edits into a live profile.

`sandbox_templates/skills/myclickup/` arrives the same way, pair-vendored with
its wheel so the text can never describe a version the image does not have. A
local edit there is reverted by the next vendor run — `just tools-check` fails
on the drift first, and it fails on CONTENT, not just on a hash: it extracts the
wheel and diffs it against the source commit the manifest claims, whenever the
member checkout is reachable.

## Vendored wheels (private tools)

```bash
just vendor-tools              # consume the channel into the build context (verifies every hash first)
just tools-check               # fail if the lock fell behind, or an artifact disagrees with its source
scripts/profile.sh build       # bake it into the shared image  <-- `up` does NOT rebuild
scripts/profile.sh <p> recreate  # per profile; also re-reads secrets.env
```

The payload (`sandbox_templates/wheels/*.whl`, `sandbox_templates/skills/myclickup/`)
is **gitignored**: this repo is public, `myclickup` is private, and a
`py3-none-any` wheel is a zip of the source. So a fresh clone has no payload —
the `Dockerfile` installs conditionally and the resulting image simply has no
`myclickup`. Source path: `$MYCLICKUP_DIR` or `.myclickup-dir.local`.

Order is load-bearing in one place: **vendor before build.** The skill half
converges like any other on the next `up`, but the wheel half only exists in a
freshly built image, and a converged skill in front of a missing CLI is exactly
the failure the vendoring couples them to avoid.

If the source repo is also bind-mounted into a profile, its `.venv` was likely
created in-container and its console scripts carry `#!/workspace/...` shebangs.
Host-side that surfaces as `Failed to spawn: pytest`, which reads as a missing
dev dependency. The vendor script sidesteps it with its own
`UV_PROJECT_ENVIRONMENT` outside the checkout — don't "fix" it by rebuilding the
shared `.venv`, which just breaks the container's copy instead.

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
