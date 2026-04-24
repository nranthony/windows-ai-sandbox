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

# Seed claude-home/settings.json with our restricted-agent template if the
# profile doesn't have one yet. Only runs on first `up` — use `profile.sh
# <p> reset-settings` to re-seed after the template changes.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEED="$SCRIPT_DIR/config/claude-settings.json"
DEST="$BASE/claude-home/settings.json"
if [[ ! -f "$DEST" ]] && [[ -f "$SEED" ]]; then
  cp "$SEED" "$DEST"
fi

# Defensive credential-helper scrub — audit Finding C, layer 2.
# VS Code Dev Containers can inject a host-routed git credential.helper into
# .config/git/config (via VSCODE_GIT_IPC_HANDLE + a node shim in
# .vscode-server). That helper forwards git auth to the host's credential
# manager, bypassing the sandbox's network identity entirely. Strip any
# credential.helper on every `up` so the setting can't survive a recreate
# even if the host's `dev.containers.copyGitConfig: false` gets reverted.
if [[ -f "$BASE/config/git/config" ]]; then
  git config --file "$BASE/config/git/config" --unset-all credential.helper 2>/dev/null || true
fi

echo "profile state ready: $BASE"
