#!/usr/bin/env bash
# =============================================================================
# run-ephemeral.sh — one-off hardened run for an existing profile, --rm on exit
# =============================================================================
# Usage:
#   scripts/run-ephemeral.sh <profile> [command...]
# Example:
#   scripts/run-ephemeral.sh alpha
#   scripts/run-ephemeral.sh alpha claude
#
# Spawns a fresh disposable container with the same hardening as the persistent
# agent, attached to the per-profile sandbox-internal network so it can reach
# egress-proxy. Requires the compose stack for <profile> to already be up
# (`scripts/profile.sh <profile> up`) — this script does NOT start Squid; it
# borrows the one compose already started.
#
# Why this exists alongside `scripts/profile.sh exec`:
#   - profile.sh exec runs inside the *persistent* ai-sandbox-<profile>
#     container. Anything it writes to /tmp, .npm-global, .local persists
#     across invocations.
#   - run-ephemeral.sh spawns a fresh --rm container with the same hardening;
#     everything outside the bind mounts is discarded on exit. Useful for
#     one-shot "try this command in a clean shell" checks.
# =============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="${WIN_AI_REPO_ROOT:-$HOME/repo}"
PROFILES_ROOT="${WIN_AI_PROFILES_ROOT:-$HOME/.ai-sandbox/profiles}"

PROFILE="${1:-}"
[[ -n "$PROFILE" ]] || { echo "Usage: $0 <profile> [command...]" >&2; exit 1; }
[[ "$PROFILE" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "profile name must match [a-zA-Z0-9_-]+" >&2; exit 1; }
shift

REPO_PATH="$REPO_ROOT/$PROFILE"
STATE="$PROFILES_ROOT/$PROFILE"
NETWORK="ai-sandbox-${PROFILE}_sandbox-internal"

[[ -d "$REPO_PATH" ]] || { echo "No such profile workspace: $REPO_PATH" >&2; exit 1; }
[[ -d "$STATE"     ]] || { echo "No profile state dir: $STATE
  Run: scripts/profile.sh $PROFILE up" >&2; exit 1; }
[[ -s "$STATE/claude.json" ]] || { echo "Missing $STATE/claude.json
  Run: scripts/profile.sh $PROFILE up" >&2; exit 1; }
docker network inspect "$NETWORK" >/dev/null 2>&1 \
  || { echo "Network $NETWORK missing — bring the stack up first:
  scripts/profile.sh $PROFILE up" >&2; exit 1; }

# Container runs as root (UID 0) under rootless Docker userns=host —
# matches docker-compose.yml. tmpfs default ownership is root:root, no
# explicit uid= needed (vs macolima which has agent UID 1000).
docker run --rm -it \
  --name "ai-sandbox-ephemeral-${PROFILE}-$$" \
  --hostname "ai-sandbox-${PROFILE}-ephemeral" \
  --tmpfs /tmp:size=1g,noexec,nosuid,nodev \
  --tmpfs /run:size=64m,noexec,nosuid,nodev \
  --tmpfs /root/.npm-global:size=512m,noexec,nosuid,nodev \
  --tmpfs /root/.local:size=256m,noexec,nosuid,nodev \
  --security-opt no-new-privileges:true \
  --security-opt "seccomp=$REPO/seccomp.json" \
  --cap-drop ALL \
  --pids-limit 512 \
  --memory 8g --memory-swap 8g \
  --cpus 4 \
  --network "$NETWORK" \
  --device /dev/dxg \
  -e LD_LIBRARY_PATH=/usr/lib/wsl/lib \
  -e HTTP_PROXY=http://egress-proxy:3128 \
  -e HTTPS_PROXY=http://egress-proxy:3128 \
  -e http_proxy=http://egress-proxy:3128 \
  -e https_proxy=http://egress-proxy:3128 \
  -e NO_PROXY=localhost,127.0.0.1,egress-proxy \
  -e GIT_CONFIG_GLOBAL=/root/.config/git/config \
  -e SANDBOX_PROFILE="$PROFILE" \
  -v "$REPO_PATH":/workspace:rw \
  -v /usr/lib/wsl:/usr/lib/wsl:ro \
  -v "$STATE/claude-home":/root/.claude:rw \
  -v "$STATE/claude.json":/root/.claude.json:rw \
  -v "$STATE/cache":/root/.cache:rw \
  -v "$STATE/config":/root/.config:rw \
  -w /workspace \
  windows-ai-sandbox:latest \
  "${@:-zsh}"
