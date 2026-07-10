#!/usr/bin/env bash
# =============================================================================
# init-profile-state.sh — idempotent bootstrap for a profile's persistent state
# =============================================================================
# Usage:  scripts/init-profile-state.sh <profile>
#
# Creates ~/.ai-sandbox/profiles/<profile>/ with the directory layout the
# compose file expects, and seeds claude.json with '{}' so Claude Code's
# first run doesn't hit "invalid JSON: Unexpected EOF" on an empty file.
# =============================================================================
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <profile>" >&2; exit 1; }
PROFILE="$1"

[[ "$PROFILE" =~ ^[a-zA-Z0-9_-]+$ ]] \
  || { echo "profile name must match [a-zA-Z0-9_-]+" >&2; exit 1; }

BASE="${HOME}/.ai-sandbox/profiles/$PROFILE"

mkdir -p \
  "$BASE/claude-home" \
  "$BASE/cache" \
  "$BASE/config/gh" \
  "$BASE/config/glab-cli" \
  "$BASE/config/git" \
  "$BASE/gemini-home"

# Single-file bind mount target — must exist on host, non-empty JSON.
if [[ ! -s "$BASE/claude.json" ]]; then
  printf '{}\n' > "$BASE/claude.json"
fi
chmod 644 "$BASE/claude.json"

# Seed claude-home/settings.json with our restricted-agent template if the
# profile doesn't have one yet. Only runs on first `up` — use `profile.sh
# <p> reset-settings` to re-seed after the template changes.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEED="$SCRIPT_DIR/sandbox_templates/claude/claude-settings.json"
DEST="$BASE/claude-home/settings.json"
if [[ ! -f "$DEST" ]] && [[ -f "$SEED" ]]; then
  cp "$SEED" "$DEST"
fi

# Defensive credential-helper scrub — audit Finding C, layer 2.
# VS Code Dev Containers can inject a host-routed git credential.helper into
# .config/git/config (via VSCODE_GIT_IPC_HANDLE + a node shim in
# .vscode-server), and copyGitConfig can leak host helpers like
# git-credential-manager. Both forward git auth to the host, bypassing the
# sandbox's network identity. Strip those on every `up` — but leave benign
# in-container helpers alone (glab and gh's own credential shims, which use
# in-container tokens from ~/.config/<tool>/). Mirrors verify-sandbox.sh's
# narrower grep so the tripwire and scrub agree on what counts as drift.
if [[ -f "$BASE/config/git/config" ]] && \
   grep -qE 'helper\s*=.*(vscode-server|vscode-remote-containers|git-credential-manager)' \
     "$BASE/config/git/config"; then
  awk '
    /^[[:space:]]*helper[[:space:]]*=.*(vscode-server|vscode-remote-containers|git-credential-manager)/ { next }
    { print }
  ' "$BASE/config/git/config" > "$BASE/config/git/config.scrubbed" \
    && mv "$BASE/config/git/config.scrubbed" "$BASE/config/git/config"
fi

# Git identity: seed AND enforce a noreply address on every run. This file is
# the container's GIT_CONFIG_GLOBAL, so it governs every repo under
# /workspace — commits authored in the sandbox must never carry a personal
# email. GIT_USER_NAME/GIT_USER_EMAIL override the defaults, but an override
# email that is not a users.noreply.github.com address is refused (that is
# the whole guarantee). Mirrors ensure_state in profile.sh.
GIT_ID_NAME="${GIT_USER_NAME:-nranthony}"
GIT_ID_EMAIL="${GIT_USER_EMAIL:-16306836+nranthony@users.noreply.github.com}"
if [[ "$GIT_ID_EMAIL" != *@users.noreply.github.com ]]; then
  echo "warning: GIT_USER_EMAIL '$GIT_ID_EMAIL' is not a users.noreply.github.com address — using default noreply identity" >&2
  GIT_ID_NAME="nranthony"
  GIT_ID_EMAIL="16306836+nranthony@users.noreply.github.com"
fi
CUR_EMAIL=""
[[ -f "$BASE/config/git/config" ]] && \
  CUR_EMAIL="$(git config --file "$BASE/config/git/config" user.email 2>/dev/null || true)"
if [[ "$CUR_EMAIL" != *@users.noreply.github.com ]]; then
  git config --file "$BASE/config/git/config" user.name  "$GIT_ID_NAME"
  git config --file "$BASE/config/git/config" user.email "$GIT_ID_EMAIL"
fi

echo "profile state ready: $BASE"
