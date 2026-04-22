#!/usr/bin/env bash
# =============================================================================
# profile.sh — multi-profile entry point for the windows-ai-sandbox stack
# =============================================================================
# Usage:
#   scripts/profile.sh <profile> <command> [extra args...]
#   scripts/profile.sh list
#
# Commands:
#   up              start the stack for this profile (creates state dirs)
#   down            stop + remove containers (keeps persistent state)
#   attach          zsh into the agent container as root
#   auth            run `claude login` inside the container
#   auth-github     run `gh auth login` inside the container
#   auth-gitlab     run `glab auth login` inside the container
#   logs            tail container logs
#   status          docker compose ps for this profile
#   build           force-rebuild the shared image (all profiles pick it up)
#   rebuild         build + recreate this profile's container
#   list            list all existing profiles with up/down status
#   exec <cmd...>   run arbitrary command inside the container
# =============================================================================
set -euo pipefail

REPO_ROOT="${HOME}/repo"
PROFILES_ROOT="${HOME}/.ai-sandbox/profiles"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

info()  { printf '\033[0;36m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
fail()  { printf '\033[0;31m[FAIL]\033[0m  %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,/^# =====/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

# --- `list` is the only command that doesn't take a profile arg --------------
if [[ "${1:-}" == "list" ]]; then
  if [[ ! -d "$PROFILES_ROOT" ]]; then
    echo "(no profiles yet — try: scripts/profile.sh <name> up)"
    exit 0
  fi
  echo "Profiles under $PROFILES_ROOT:"
  shopt -s nullglob
  for d in "$PROFILES_ROOT"/*/; do
    name="$(basename "$d")"
    status="down"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "ai-sandbox-$name"; then
      status="up"
    fi
    repo_dir="$REPO_ROOT/$name"
    [[ -d "$repo_dir" ]] || repo_dir="$repo_dir (MISSING)"
    printf '  %-20s %-6s %s\n' "$name" "$status" "$repo_dir"
  done
  exit 0
fi

# --- global `build` (no profile needed) --------------------------------------
if [[ "${1:-}" == "build" ]]; then
  info "Building windows-ai-sandbox:latest"
  cd "$SCRIPT_DIR"
  # PROFILE is required by compose's interpolation even for build-only.
  PROFILE=_build docker compose build ai-sandbox
  exit 0
fi

# --- arg parsing -------------------------------------------------------------
[[ $# -ge 2 ]] || usage

PROFILE="$1"
CMD="$2"
shift 2

[[ "$PROFILE" =~ ^[a-zA-Z0-9_-]+$ ]] \
  || fail "Profile name must match [a-zA-Z0-9_-]+ (got: $PROFILE)"

export PROFILE
export COMPOSE_PROJECT_NAME="ai-sandbox-$PROFILE"
AGENT="ai-sandbox-$PROFILE"

cd "$SCRIPT_DIR"

ensure_repo_dir() {
  if [[ ! -d "$REPO_ROOT/$PROFILE" ]]; then
    fail "Repo dir does not exist: $REPO_ROOT/$PROFILE
      Create it first:  mkdir -p '$REPO_ROOT/$PROFILE'
      Or clone repos into it before bringing the stack up."
  fi
}

ensure_network() {
  if ! docker network inspect ai-sandbox >/dev/null 2>&1; then
    fail "Docker network 'ai-sandbox' not found. Run host_setup/setup-rootless-docker-wsl.sh first."
  fi
}

# --- dispatch ----------------------------------------------------------------
case "$CMD" in
  up)
    ensure_repo_dir
    ensure_network
    bash "$SCRIPT_DIR/scripts/init-profile-state.sh" "$PROFILE"
    info "Bringing up profile '$PROFILE' (project: $COMPOSE_PROJECT_NAME)"
    docker compose up -d "$@"
    ok "Stack up. Attach with:  scripts/profile.sh $PROFILE attach"
    ;;

  down)
    info "Taking down profile '$PROFILE'"
    docker compose down "$@"
    ok "Stack down. Persistent state preserved under $PROFILES_ROOT/$PROFILE/"
    ;;

  attach)
    info "Attaching to $AGENT (Ctrl-D to exit)"
    exec docker exec -it "$AGENT" zsh
    ;;

  auth)
    info "Running 'claude login' inside $AGENT"
    exec docker exec -it "$AGENT" claude login
    ;;

  auth-github)
    info "Running 'gh auth login' inside $AGENT"
    exec docker exec -it "$AGENT" gh auth login
    ;;

  auth-gitlab)
    info "Running 'glab auth login' inside $AGENT"
    exec docker exec -it "$AGENT" glab auth login
    ;;

  logs)
    exec docker compose logs -f "$@"
    ;;

  status|ps)
    exec docker compose ps "$@"
    ;;

  rebuild)
    ensure_repo_dir
    ensure_network
    bash "$SCRIPT_DIR/scripts/init-profile-state.sh" "$PROFILE"
    info "Rebuilding image + recreating profile '$PROFILE'"
    docker compose build ai-sandbox
    docker compose up -d --force-recreate
    ;;

  exec)
    [[ $# -ge 1 ]] || fail "Usage: scripts/profile.sh $PROFILE exec <cmd> [args...]"
    exec docker exec -it "$AGENT" "$@"
    ;;

  *)
    usage
    ;;
esac
