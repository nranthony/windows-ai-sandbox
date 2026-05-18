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
#   reset-settings  overwrite this profile's claude settings.json from
#                   config/claude-settings.json (backs up the old one)
#   clean           prune rotating state (old .claude.json backups, paste-cache,
#                   shell-snapshots). Pass --deep to also drop MCP debug logs
#                   and settings.json.bak.* backups.
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

# --- dispatch ----------------------------------------------------------------
case "$CMD" in
  up)
    ensure_repo_dir
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
    bash "$SCRIPT_DIR/scripts/init-profile-state.sh" "$PROFILE"
    info "Rebuilding image + recreating profile '$PROFILE'"
    docker compose build ai-sandbox
    docker compose up -d --force-recreate
    ;;

  exec)
    [[ $# -ge 1 ]] || fail "Usage: scripts/profile.sh $PROFILE exec <cmd> [args...]"
    exec docker exec -it "$AGENT" "$@"
    ;;

  verify)
    # Stream the host-side tripwire into the container via stdin. The sandbox
    # repo itself is NOT bind-mounted into /workspace (by design — workspace
    # holds the user's profile repos, not the sandbox tooling), so a path
    # like /workspace/windows-ai-sandbox/scripts/verify-sandbox.sh would not
    # resolve. `bash -s` reads the script from stdin and runs it inside the
    # container with the host file as source of truth.
    src="$SCRIPT_DIR/scripts/verify-sandbox.sh"
    [[ -f "$src" ]] || fail "verify-sandbox.sh missing: $src"
    info "Running verify-sandbox.sh inside $AGENT (streamed via stdin)"
    exec docker exec -i "$AGENT" bash -s -- "$@" < "$src"
    ;;

  audit)
    # Tier 2 of the 3-tier audit model (tripwire → JSON → agent report).
    # Stage sandbox config + audit probes into the profile workspace (so the
    # probes' static checks of seccomp.json/squid.conf/etc. have files to
    # read at /workspace/temp_audit_package/), then run audit.sh inside the
    # container, and write the JSON next to the live claude state on the
    # host so it's accessible without re-attaching.
    #
    # Flags:
    #   --stage-only   stage the package, don't run audit
    #   --clean        remove the staged package
    #   --compact      pass-through to aggregate.py (one-line JSON)
    flag=""
    for a in "$@"; do
      case "$a" in
        --stage-only|--clean|--compact) flag="$a" ;;
      esac
    done

    if [[ "$flag" == "--clean" ]]; then
      exec bash "$SCRIPT_DIR/scripts/stage-audit-package.sh" "$PROFILE" --clean
    fi

    info "Staging audit package for '$PROFILE'"
    bash "$SCRIPT_DIR/scripts/stage-audit-package.sh" "$PROFILE"

    if [[ "$flag" == "--stage-only" ]]; then
      ok "Stage complete. Run audit with:  scripts/profile.sh $PROFILE audit"
      exit 0
    fi

    stamp=$(date -u +%Y-%m-%dT%H-%M-%SZ)
    audits_host="$PROFILES_ROOT/$PROFILE/claude-home/audits"
    mkdir -p "$audits_host"
    json_host="$audits_host/$stamp-$PROFILE-audit.json"

    info "Running audit inside $AGENT → $json_host"
    pretty_flag=""
    [[ "$flag" == "--compact" ]] && pretty_flag="--compact"
    if docker exec "$AGENT" bash /workspace/temp_audit_package/scripts/audit/audit.sh $pretty_flag > "$json_host"; then
      ok "Audit JSON saved: $json_host"
      ok "Container path:   /root/.claude/audits/$stamp-$PROFILE-audit.json"
      # Brief verdict summary if jq is available host-side.
      if command -v jq >/dev/null 2>&1; then
        info "Summary: $(jq -c .summary "$json_host")"
      fi
    else
      fail "Audit run failed; partial JSON at $json_host"
    fi
    ;;

  reset-settings)
    # Overwrite this profile's claude-home/settings.json from the template.
    # init-profile-state.sh only seeds when absent; use this when the
    # template evolves and you want to apply it to an existing profile.
    src="$SCRIPT_DIR/config/claude-settings.json"
    dst="$PROFILES_ROOT/$PROFILE/claude-home/settings.json"
    [[ -f "$src" ]] || fail "template missing: $src"
    mkdir -p "$(dirname "$dst")"
    if [[ -f "$dst" ]]; then
      backup="$dst.bak.$(date +%Y%m%d-%H%M%S)"
      cp "$dst" "$backup"
      info "backed up existing settings → $backup"
    fi
    cp "$src" "$dst"
    ok "settings.json reset for '$PROFILE'. Restart claude inside the container to pick up."
    ;;

  clean)
    # Prune rotating state that Claude/npm/zsh regenerate on demand. Safe by default.
    # --deep also drops MCP debug logs and reset-settings backups.
    # Never touches: .credentials.json, live settings.json, live claude.json,
    # file-history, projects/, plugins/, gitstatusd binary.
    deep=0
    for a in "$@"; do [[ "$a" == "--deep" ]] && deep=1; done
    p="$PROFILES_ROOT/$PROFILE"
    [[ -d "$p" ]] || fail "no state dir: $p"

    info "cleaning $p (deep=$deep)"

    # Claude Code's own rotating .claude.json backups — keep the single newest.
    bdir="$p/claude-home/backups"
    if [[ -d "$bdir" ]]; then
      # shellcheck disable=SC2012
      ls -t "$bdir"/.claude.json.backup.* 2>/dev/null | tail -n +2 | xargs -r rm -f
      rm -f "$bdir"/.claude.json.corrupted.* 2>/dev/null || true
      ok "pruned $bdir (kept newest .claude.json.backup)"
    fi

    # Paste cache and shell snapshots — regenerated per session.
    rm -rf "$p/claude-home/paste-cache" "$p/claude-home/shell-snapshots" 2>/dev/null || true
    mkdir -p "$p/claude-home/paste-cache" "$p/claude-home/shell-snapshots"
    ok "reset paste-cache + shell-snapshots"

    if [[ "$deep" == "1" ]]; then
      find "$p/cache/claude-cli-nodejs" -type f -name '*.jsonl' -delete 2>/dev/null || true
      ok "dropped MCP debug logs under cache/claude-cli-nodejs"
      find "$p/claude-home" -maxdepth 1 -name 'settings.json.bak.*' -delete 2>/dev/null || true
      ok "dropped settings.json.bak.* backups"
    else
      info "skip --deep targets (MCP logs, settings.json.bak.*) — pass --deep to include"
    fi

    ok "clean done for '$PROFILE'"
    ;;

  *)
    usage
    ;;
esac
