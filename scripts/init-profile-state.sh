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
  "$BASE/config/pnpm" \
  "$BASE/gemini-home" \
  "$BASE/gemini-home/config" \
  "$BASE/gemini-home/antigravity-cli" \
  "$BASE/kaggle" \
  "$BASE/audit"

# Ollama model store. Deliberately NOT under $BASE — it is SHARED by every
# profile (~/.ai-sandbox/models/ollama), because model blobs run to many GB and
# duplicating them per profile is pure waste. Sharing is safe only because the
# runtime mount is READ-ONLY (docker-compose.yml): Ollama's API can create and
# delete models, so a writable shared store would let one profile plant a
# Modelfile another profile then runs. Writes happen only through the host-side
# `profile.sh <p> ollama pull|create|rm` helper. Mirrors ensure_state in
# profile.sh. Created unconditionally so the :ro bind mount has a target even
# for profiles that never enable the sibling.
mkdir -p "${HOME}/.ai-sandbox/models/ollama"

# audit/ holds depgate.jsonl — one JSON line per with-egress.sh install window
# (phase 3, T22). HOST side and not bind-mounted into any container: the proxy's
# own access.log lives on tmpfs and dies with the container (gap G7), which is
# exactly the state-placement mistake AGENTS.md warns about. Losing the install
# history would hurt, so it does not live in a container layer.

# pnpm: always run the image's pnpm; ignore repo `packageManager` pins. pnpm
# 10's built-in version manager downloads the pinned version into
# ~/.local/share/pnpm/.tools/ and re-execs it, but /root/.local is a noexec
# tmpfs (docker-compose.yml, audit Finding G), so the re-exec dies with EACCES
# and every pnpm command fails in any repo whose pin drifts from the image.
# The opt-out lives in pnpm's global rc (~/.config/pnpm/rc) — npm never reads
# that file, so no "Unknown config" warnings. Pins stay honored on host/CI.
# Mirrors ensure_state in profile.sh.
if ! grep -qs '^manage-package-manager-versions=' "$BASE/config/pnpm/rc"; then
  printf 'manage-package-manager-versions=false\n' >> "$BASE/config/pnpm/rc"
fi

# Gate 2 (pnpm half): refuse to resolve anything published in the last 7 days —
# the slopsquat quarantine. The npm and pip halves live in the image
# (Dockerfile, "Gate 2" block); pnpm's has to live HERE because pnpm reads
# ~/.config/pnpm/rc, and /root/.config is a per-profile BIND MOUNT — a value
# written into the image layer would be masked by the mount at runtime.
#
# UNITS DIFFER FROM npm: pnpm's setting is in MINUTES, npm's min-release-age is
# in DAYS. 10080 = 7 * 24 * 60. Getting this wrong by a factor of 1440 fails
# OPEN (7 minutes of quarantine), which is why the value carries the arithmetic.
#
# KEY MUST BE KEBAB-CASE. pnpm documents the setting as `minimumReleaseAge`, but
# in the rc file that spelling is silently ignored — `pnpm config get
# minimumReleaseAge` returns `undefined`. Written as `minimum-release-age` it
# resolves under both spellings. Same convention as the line above. Verified in
# the image 2026-07-31; the verify-sandbox.sh tripwire is what caught it.
#
# Create-only, like the line above: an operator who deliberately lowers this for
# one profile keeps their change across `up`. scripts/verify-sandbox.sh asserts
# the live value, so a drop to nothing still surfaces within one cycle.
if ! grep -qs '^minimum-release-age=' "$BASE/config/pnpm/rc"; then
  printf 'minimum-release-age=10080\n' >> "$BASE/config/pnpm/rc"
fi

# Single-file bind mount target — must exist on host, non-empty JSON.
if [[ ! -s "$BASE/claude.json" ]]; then
  printf '{}\n' > "$BASE/claude.json"
fi
chmod 644 "$BASE/claude.json"

# Bootstrap claude-home/settings.json from the restricted-agent template if the
# profile doesn't have one yet. This is the BOOTSTRAP half only: since
# work/0011 the file is no longer create-only — `profile.sh ensure_state`
# CONVERGES it on every `up` (the sandbox-owned keys are overwritten from the
# template, anything else is captured to claude-home/settings.discarded.json
# first), and `profile.sh <p> converge` runs the same thing without touching
# containers. Seeding here still matters only for the path where init runs
# before ensure_state; the two agree by construction because the converge
# rewrites whatever this wrote.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEED="$SCRIPT_DIR/sandbox_templates/claude/claude-settings.json"
DEST="$BASE/claude-home/settings.json"
if [[ ! -f "$DEST" ]] && [[ -f "$SEED" ]]; then
  cp "$SEED" "$DEST"
fi

# Antigravity (`agy`) policy. Unlike the claude settings above this is NOT
# create-only — `profile.sh ensure_state` converges it on every `up`, because a
# security guardrail that lags its template is the failure this repo keeps
# re-learning (ADR-0005, ADR-0006). Seeding it here too only matters for the
# path where init runs before ensure_state; the two agree by construction
# because both call the same convergence.
#
# The agy settings.json is MERGED, never overwritten: agy stores colorScheme,
# model and trustedWorkspaces in that same file. See
# sandbox_templates/antigravity/README.md.
AGY_TPL="$SCRIPT_DIR/sandbox_templates/antigravity"
if [[ -d "$AGY_TPL" ]]; then
  [[ -f "$AGY_TPL/hooks.json" ]] && cp "$AGY_TPL/hooks.json" "$BASE/gemini-home/config/hooks.json"
  if [[ -f "$AGY_TPL/antigravity-settings.json" ]] && command -v python3 >/dev/null 2>&1; then
    SRC="$AGY_TPL/antigravity-settings.json" \
    DST="$BASE/gemini-home/antigravity-cli/settings.json" \
    python3 - <<'PYMERGE' || echo "warning: could not merge antigravity permissions" >&2
import json, os
src, dst = os.environ["SRC"], os.environ["DST"]
tpl = json.load(open(src))
live = {}
if os.path.exists(dst) and os.path.getsize(dst):
    live = json.load(open(dst))
for k in ("permissions", "toolPermission"):
    if k in tpl:
        live[k] = tpl[k]
with open(dst, "w") as fh:
    json.dump(live, fh, indent=2)
    fh.write("\n")
PYMERGE
  fi
fi

# Seed a secrets.env.example (API keys for the webfetch broker etc.) and lock
# down any real secrets.env to 600. secrets.env itself is optional and injected
# as required:false — profiles without keys still come up. Mirrors ensure_state.
SECRETS_TEMPLATE="$SCRIPT_DIR/sandbox_templates/common/secrets.env.template"
[[ -f "$SECRETS_TEMPLATE" ]] && cp "$SECRETS_TEMPLATE" "$BASE/secrets.env.example"
if [[ -f "$BASE/secrets.env" ]]; then
  chmod 600 "$BASE/secrets.env" 2>/dev/null || \
    echo "warning: could not chmod 600 $BASE/secrets.env" >&2
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
GIT_ID_NAME="${GIT_USER_NAME:-Sandbox User}"
GIT_ID_EMAIL="${GIT_USER_EMAIL:-sandbox@users.noreply.github.com}"
if [[ "$GIT_ID_EMAIL" != *@users.noreply.github.com ]]; then
  echo "warning: GIT_USER_EMAIL '$GIT_ID_EMAIL' is not a users.noreply.github.com address — using default noreply identity" >&2
  GIT_ID_NAME="Sandbox User"
  GIT_ID_EMAIL="sandbox@users.noreply.github.com"
fi
CUR_EMAIL=""
[[ -f "$BASE/config/git/config" ]] && \
  CUR_EMAIL="$(git config --file "$BASE/config/git/config" user.email 2>/dev/null || true)"
if [[ "$CUR_EMAIL" != *@users.noreply.github.com ]]; then
  git config --file "$BASE/config/git/config" user.name  "$GIT_ID_NAME"
  git config --file "$BASE/config/git/config" user.email "$GIT_ID_EMAIL"
fi

echo "profile state ready: $BASE"
