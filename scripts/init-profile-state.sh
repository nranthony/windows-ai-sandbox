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
  "$BASE/config/git"

# Single-file bind mount target — must exist on host, non-empty JSON.
if [[ ! -s "$BASE/claude.json" ]]; then
  printf '{}\n' > "$BASE/claude.json"
fi
chmod 644 "$BASE/claude.json"

echo "profile state ready: $BASE"
