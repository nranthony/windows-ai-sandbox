# justfile — discoverable front door over scripts/profile.sh + scripts/setup.sh
# =============================================================================
# CONVENIENCE LAYER ONLY. The bash scripts remain canonical (see CLAUDE.md).
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
#   - extra recipes for this repo's `auth-gemini` and `audit` commands.
#
# Exceptions (no profile arg): `list`, `build`.
# =============================================================================

profile_sh := justfile_directory() / "scripts" / "profile.sh"
setup_sh   := justfile_directory() / "scripts" / "setup.sh"

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

# rebuild the image + recreate this profile's containers. Accepts --no-cache / --pull / --expose-dev.
rebuild profile *args:
    {{profile_sh}} {{profile}} rebuild {{args}}

# force-rebuild the shared image (no profile arg). Accepts --no-cache / --pull.
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

# list all existing profiles with up/down status (no profile arg)
list:
    {{profile_sh}} list

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

# `gemini` inside the container (triggers Gemini CLI OAuth)
auth-gemini profile:
    {{profile_sh}} {{profile}} auth-gemini

# ---- hardening verification (profile.sh) ------------------------------------

# tier-1 hardening tripwire (fast pass/fail in-container check)
verify profile:
    {{profile_sh}} {{profile}} verify

# tier-2 structured audit (~80 probes, JSON to host). Accepts --stage-only / --clean.
audit profile *args:
    {{profile_sh}} {{profile}} audit {{args}}

# ---- state management (profile.sh) ------------------------------------------

# prune rotating state (old backups, paste-cache, shell-snapshots). Accepts --deep.
clean profile *args:
    {{profile_sh}} {{profile}} clean {{args}}

# wipe per-profile state but KEEP auth. Accepts --dry-run / --yes / --all-volumes.
wipe profile *args:
    {{profile_sh}} {{profile}} wipe {{args}}

# wipe the postgres data volume + fresh initdb. Accepts --yes.
db-reset profile *args:
    {{profile_sh}} {{profile}} db-reset {{args}}

# overwrite this profile's claude settings.json from config/ (backs up old)
reset-settings profile:
    {{profile_sh}} {{profile}} reset-settings

# overwrite this profile's claude skills from config/skills/ (backs up old)
reset-skills profile:
    {{profile_sh}} {{profile}} reset-skills

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
