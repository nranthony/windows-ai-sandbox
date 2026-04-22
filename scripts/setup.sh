#!/usr/bin/env bash
# =============================================================================
# setup.sh — one-shot onboarding for a new profile
# =============================================================================
# Usage:
#   scripts/setup.sh <profile> [--name "Name" --email "you@x"] [--no-auth]
#                              [--gitlab | --both] [--restart | --recreate | --verify]
#
# First-time setup (default):  brings the stack up, optionally seeds git
# identity, runs `claude login` and `gh auth login` if not already authed,
# and prints a verify block at the end. Idempotent — safe to re-run.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_SH="$SCRIPT_DIR/profile.sh"
PROFILES_ROOT="${HOME}/.ai-sandbox/profiles"

info()  { printf '\033[0;36m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
step()  { printf '\n\033[1;35m[ >> ]\033[0m  %s\n' "$*"; }
fail()  { printf '\033[0;31m[FAIL]\033[0m  %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,/^# =====/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

[[ $# -ge 1 ]] || usage
[[ "$1" == "-h" || "$1" == "--help" ]] && usage

PROFILE="$1"; shift
[[ "$PROFILE" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "Profile name must match [a-zA-Z0-9_-]+"

GIT_NAME=""
GIT_EMAIL=""
GIT_HOSTS="github"     # github | gitlab | both | none
SKIP_AUTH=0
ACTION=""              # "" | restart | recreate | verify

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)       GIT_NAME="$2"; shift 2 ;;
    --email)      GIT_EMAIL="$2"; shift 2 ;;
    --github)     GIT_HOSTS="github"; shift ;;
    --gitlab)     GIT_HOSTS="gitlab"; shift ;;
    --both)       GIT_HOSTS="both"; shift ;;
    --no-auth)    SKIP_AUTH=1; shift ;;
    --restart)    ACTION="restart"; shift ;;
    --recreate)   ACTION="recreate"; shift ;;
    --verify)     ACTION="verify"; shift ;;
    -h|--help)    usage ;;
    *)            fail "Unknown option: $1" ;;
  esac
done

export PROFILE
export COMPOSE_PROJECT_NAME="ai-sandbox-$PROFILE"
AGENT="ai-sandbox-$PROFILE"
cd "$SCRIPT_DIR/.."

# Fallback: if --name/--email not given but .env has GIT_NAME/GIT_EMAIL, use them.
if [[ -z "$GIT_NAME" || -z "$GIT_EMAIL" ]] && [[ -f .env ]]; then
  # shellcheck disable=SC1091
  set -a; source .env; set +a
  GIT_NAME="${GIT_NAME:-}"
  GIT_EMAIL="${GIT_EMAIL:-}"
fi

# --- lifecycle branches ------------------------------------------------------
case "$ACTION" in
  restart)
    step "Restarting '$PROFILE'"
    docker compose restart
    ok "Restarted."
    exit 0
    ;;
  recreate)
    step "Force-recreating '$PROFILE'"
    "$PROFILE_SH" "$PROFILE" up >/dev/null
    docker compose up -d --force-recreate
    ok "Recreated."
    exit 0
    ;;
  verify)
    step "Verifying '$PROFILE'"
    docker compose ps
    echo
    info "Claude auth:"
    docker exec "$AGENT" sh -c 'test -s /root/.claude/.credentials.json && echo "authed" || echo "(not authed)"' || true
    echo
    info "GitHub auth:"
    docker exec "$AGENT" gh auth status 2>&1 || true
    echo
    info "GitLab auth:"
    docker exec "$AGENT" glab auth status 2>&1 || true
    echo
    info "Git identity:"
    docker exec "$AGENT" git config --global --list 2>&1 || true
    exit 0
    ;;
esac

# --- setup flow --------------------------------------------------------------
step "Setting up profile '$PROFILE'"
info "Project: $COMPOSE_PROJECT_NAME   Container: $AGENT"

step "1/4  Bringing stack up"
"$PROFILE_SH" "$PROFILE" up

step "2/4  Git identity"
if [[ -n "$GIT_NAME" && -n "$GIT_EMAIL" ]]; then
  docker exec "$AGENT" git config --global user.name  "$GIT_NAME"
  docker exec "$AGENT" git config --global user.email "$GIT_EMAIL"
  docker exec "$AGENT" git config --global init.defaultBranch main
  ok "user.name='$GIT_NAME'  user.email='$GIT_EMAIL'"
else
  warn "No --name/--email (and none found in .env). Skipping git identity."
fi

step "3/4  Authentications"
if (( SKIP_AUTH )); then
  warn "Skipping (--no-auth)."
else
  # Claude
  if docker exec "$AGENT" test -s /root/.claude/.credentials.json 2>/dev/null; then
    ok "claude: already authenticated."
  else
    docker exec -it "$AGENT" claude login || warn "claude login skipped/failed"
  fi
  # gh / glab
  do_gh()   { docker exec "$AGENT" gh auth status >/dev/null 2>&1 \
                && ok "gh: already authenticated." \
                || docker exec -it "$AGENT" gh auth login; }
  do_glab() { docker exec "$AGENT" glab auth status >/dev/null 2>&1 \
                && ok "glab: already authenticated." \
                || docker exec -it "$AGENT" glab auth login; }
  case "$GIT_HOSTS" in
    github) do_gh ;;
    gitlab) do_glab ;;
    both)   do_gh; do_glab ;;
  esac
fi

step "4/4  Verify"
"$SCRIPT_DIR/setup.sh" "$PROFILE" --verify 2>&1 | sed 's/^/  /'

echo
ok "Profile '$PROFILE' is ready."
info "Attach:    scripts/profile.sh $PROFILE attach"
info "Shut down: scripts/profile.sh $PROFILE down"
