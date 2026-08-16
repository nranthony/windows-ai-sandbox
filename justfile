# justfile — front door over scripts/profile.sh + setup.sh + code-attach.sh
# =============================================================================
# CONVENIENCE LAYER ONLY. The bash scripts remain canonical (see AGENTS.md).
# Every recipe is a thin pass-through — it must NOT call `docker compose`
# directly. profile.sh/setup.sh export COMPOSE_PROJECT_NAME and PROFILE before
# invoking compose, and the compose file's `${PROFILE:?...}` guard fails fast
# without them. Reimplementing any logic here would bypass that. If you
# add/rename a command in profile.sh/setup.sh, update the matching recipe.
#
# Profile is the FIRST positional arg to every per-profile recipe, mirroring
# the scripts:
#   just up work             ->  scripts/profile.sh work up
#   just attach work         ->  scripts/profile.sh work attach
#   just verify work         ->  scripts/profile.sh work verify
#   just setup work --name "W" --email w@x
#
# DIVERGENCE FROM macolima (see docs/sibling-repo-relationship.md):
#   - NO colima-* recipes — WSL2 IS the VM; there is no start.sh/stop.sh here.
#   - `verify` fronts `profile.sh verify` (the tier-1 hardening tripwire), NOT
#     `setup.sh --verify`. Use `setup-verify` for the onboarding sanity block.
#   - `build` takes NO profile arg (profile.sh dispatches it profile-less).
#   - extra recipes for this repo's `auth-antigravity` and `audit` commands.
#
# Exceptions (no profile arg): `list`, `build`.
# =============================================================================

profile_sh := justfile_directory() / "scripts" / "profile.sh"
setup_sh   := justfile_directory() / "scripts" / "setup.sh"
code_sh    := justfile_directory() / "scripts" / "code-attach.sh"
gc_sh      := justfile_directory() / "scripts" / "docker-gc.sh"
vendortools_sh := justfile_directory() / "scripts" / "vendor-tools.sh"

# default: banner + recipe list (a bare `just` lists, never runs a recipe).
_default:
    @echo "windows-ai-sandbox — sandbox lifecycle. Canonical: scripts/profile.sh, scripts/setup.sh"
    @echo "Usage: just <recipe> <profile> [args]   (e.g. just up work; then: just attach work)"
    @echo
    @just --list

# ---- lifecycle (profile.sh) -------------------------------------------------

# build (if needed) + start the stack for a profile. Accepts --expose-dev.
up profile *args:
    {{profile_sh}} {{profile}} up {{args}}

# stop + remove containers (keeps persistent state; age-prunes old logs)
down profile:
    {{profile_sh}} {{profile}} down

# force-recreate containers — picks up compose/seccomp/proxy/mount/dns changes (no image rebuild). Accepts --expose-dev.
recreate profile *args:
    {{profile_sh}} {{profile}} recreate {{args}}

# force-recreate EVERY running profile onto the current image (no profile arg). Use after `build`.
recreate-all *args:
    {{profile_sh}} recreate-all {{args}}

# rebuild the image + recreate this profile's containers. Accepts --no-cache / --pull / --expose-dev.
rebuild profile *args:
    {{profile_sh}} {{profile}} rebuild {{args}}

# force-rebuild the shared image (no profile arg).
# Accepts --no-cache / --pull / --refresh-ai / --claude-version=X.Y.Z / --recreate-running.
build *args:
    {{profile_sh}} build {{args}}

# shell into the agent container (zsh as root). Primary entry point — attach-only.
attach profile:
    {{profile_sh}} {{profile}} attach

# tail container logs
logs profile:
    {{profile_sh}} {{profile}} logs

# docker compose ps for this profile
status profile:
    {{profile_sh}} {{profile}} status

# run an arbitrary command inside the agent container
exec profile *args:
    {{profile_sh}} {{profile}} exec {{args}}

# manage the pipeline FastAPI (uvicorn :8001) in the agent. Sub: up (default)|down|status|logs
api profile *args:
    {{profile_sh}} {{profile}} api {{args}}

# list all existing profiles with up/down status (no profile arg)
list:
    {{profile_sh}} list

# cross-profile health: flag any profile whose agent/proxy/DB aren't all up together (no profile arg)
health:
    {{profile_sh}} health

# ---- VS Code (host-side, code-attach.sh) ------------------------------------
#
# Pins the folder by URI, so it does NOT reopen whatever folder you had open
# last (as "Attach to Running Container" does) and needs no devcontainer.json.
# Omit the folder to list what's under /workspace. Trailing args pass through
# to `code`, e.g. `just code work app_blast -r` reuses the current window.

# open a specific folder in the running agent container in VS Code
code profile *args:
    {{code_sh}} {{profile}} {{args}}

# ---- auth (profile.sh) ------------------------------------------------------

# `claude login` inside the container (one-time per profile)
auth profile:
    {{profile_sh}} {{profile}} auth

# `gh auth login` inside the container
auth-github profile:
    {{profile_sh}} {{profile}} auth-github

# `glab auth login` inside the container
auth-gitlab profile:
    {{profile_sh}} {{profile}} auth-gitlab

# `agy` (Antigravity CLI) inside the container — interactive console sign-in
auth-antigravity profile:
    {{profile_sh}} {{profile}} auth-antigravity

# ---- hardening verification (profile.sh) ------------------------------------

# tier-1 hardening tripwire (fast pass/fail in-container check)
verify profile:
    {{profile_sh}} {{profile}} verify

# tier-2 structured audit (~80 probes, JSON to host). Accepts --stage-only / --clean.
audit profile *args:
    {{profile_sh}} {{profile}} audit {{args}}

# dependency posture for a profile's workspace (host-side, read-only; --osv adds the OSV malicious-package check)
deps profile *args:
    {{profile_sh}} {{profile}} deps {{args}}

# offline test suites — no docker, no network, no profile. Run before committing
# a change to any file they gate (see AGENTS.md).
test-offline:
    bash {{justfile_directory()}}/sandbox_templates/claude/hooks/deny-destructive.test.sh
    bash {{justfile_directory()}}/scripts/depaudit.test.sh
    bash {{justfile_directory()}}/scripts/with-egress.test.sh
    bash {{justfile_directory()}}/scripts/dockerfile-order.test.sh
    bash {{justfile_directory()}}/scripts/profile-skills.test.sh
    bash {{justfile_directory()}}/scripts/vendor-tools.test.sh
    @just --justfile {{justfile()}} check-upstreams

# build-layer ordering tripwire (Dockerfile only; see the header for why the
# order is load-bearing)
test-dockerfile:
    bash {{justfile_directory()}}/scripts/dockerfile-order.test.sh

# ---- state management (profile.sh) ------------------------------------------

# prune rotating state (old backups, paste-cache, shell-snapshots). Accepts --deep.
clean profile *args:
    {{profile_sh}} {{profile}} clean {{args}}

# wipe per-profile state but KEEP auth. Accepts --dry-run / --yes / --all-volumes.
wipe profile *args:
    {{profile_sh}} {{profile}} wipe {{args}}

# set this profile's default DB sibling(s) so plain `up` includes them.
# SUB: enable <postgres|mongo|all> | disable | status
db profile *args:
    {{profile_sh}} {{profile}} db {{args}}

# wipe the postgres data volume + fresh initdb. Accepts --yes.
db-reset profile *args:
    {{profile_sh}} {{profile}} db-reset {{args}}

# overwrite this profile's claude settings.json from sandbox_templates/claude/ (backs up old)
reset-settings profile:
    {{profile_sh}} {{profile}} reset-settings

# converge this profile's claude skills to sandbox_templates/skills/ (no backups, ADR-0005)
reset-skills profile:
    {{profile_sh}} {{profile}} reset-skills

# ---- vendored payload refresh (host-side, no profile arg) -------------------
#
# Developer actions, NOT lifecycle: they pull material from a sibling checkout
# into this build context. Never run during a build or `up`. Seeding converges
# (ADR-0005), so a synced skill reaches a live profile on its next `up` — or now,
# via `just reset-skills <profile>`. A vendored WHEEL is different: it is baked
# into the image, so it needs `just build` and then a recreate.

# ---- boundary monitors ------------------------------------------------------
#
# "Am I current with my upstreams?" — one command, because the answer used to
# require running two different recipes in two different checkouts, and the one
# that mattered lived in the OTHER repo. myconv sat three releases behind for
# days with nothing anywhere reporting it.
#
# Every vendored payload this repo carries gets a detector HERE, on the side
# that owns the stale copy. Offline (reads a sibling checkout — no network, no
# docker) and SKIPs loudly rather than failing where the source isn't present,
# so this is safe to run anywhere and safe to wire into test-offline. Add a line
# here whenever a new upstream payload is vendored.
#
# It is ONE recipe now, not three: `tools-check` answers for every artifact the
# channel carries, both lock-vs-published and content-vs-source. The old
# per-payload monitors retired with the per-payload vendor scripts (step 11).

# am I current with my upstreams? (offline; SKIPs loudly where a source is absent)
check-upstreams: tools-check
    @echo "upstream boundaries checked (review any [SKIP] above — a skip is not a pass)"

# ---- the depot channel (ADR-0014, work/0016 Part B) -------------------------
#
# One door for every vendored artifact. Replaced vendor-myclickup and the myconv
# leg of sync-skills at step 11, after the two mechanisms were proven equivalent
# by a zero content diff — a cutover on evidence, not on trust (plan §7).
#
# Source path: $DEPOT_DIR or .depot-dir.local. Consumes manifest.toml, verifies
# every hash before copying anything, records what it took in
# sandbox_templates/VENDORED.lock.

# vendor every channel artifact into the build context (wheel, skills, plugins)
vendor-tools *args:
    {{vendortools_sh}} {{args}}

# Content-checks each artifact against the source commit it claims whenever that
# member checkout is reachable, and says HASH-ONLY when it is not.

# fail if VENDORED.lock has fallen behind what the channel publishes
tools-check:
    {{vendortools_sh}} --check

# Informational: it never edits that file, and it cannot see what a running
# profile has (seeding is create-only) nor what the auto-mode classifier does
# with a command on none of the lists.

# report the manifest's permission proposal against the settings TEMPLATE (read-only)
check-permissions:
    {{vendortools_sh}} --permissions

# ---- host Docker hygiene (docker-gc.sh) -------------------------------------
#
# Daemon-wide, NOT per-profile: reclaims what no profile's lifecycle owns —
# stale VS Code devcontainers and their writable layers, plus BuildKit cache.
# Skips `ai-sandbox-*` containers entirely (profile.sh owns those) and only
# REPORTS dangling images/orphaned volumes. Monthly is about right.

# reclaim stale containers + build cache. Accepts --dry-run / --yes / --days N / --keep-cache SIZE.
docker-gc *args:
    {{gc_sh}} {{args}}

# ---- control dashboard (host-side Streamlit) --------------------------------

# launch the ops dashboard (activate .venv, run streamlit on 127.0.0.1:8501)
dashboard *args:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{justfile_directory()}}/dashboard
    source .venv/bin/activate
    streamlit run src/app.py {{args}}

# ---- one-shot onboarding / lifecycle flags (setup.sh) -----------------------

# full onboarding: up + git config + claude/gh auth (e.g. just setup work --name "W" --email w@x)
setup profile *args:
    {{setup_sh}} {{profile}} {{args}}

# onboarding sanity block (auth status, mounts, git config) and exit
setup-verify profile:
    {{setup_sh}} {{profile}} --verify

# docker compose restart (via setup.sh lifecycle flag)
restart profile:
    {{setup_sh}} {{profile}} --restart
