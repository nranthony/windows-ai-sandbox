#!/usr/bin/env bash
# =============================================================================
# stage-audit-package.sh — copy sandbox config into a profile's workspace
# =============================================================================
# Usage: scripts/stage-audit-package.sh <profile> [--clean]
#
# Copies sandbox config + audit infrastructure into
#   ~/repo/<profile>/temp_audit_package/
# which appears inside the agent container as /workspace/temp_audit_package/.
# The audit probes read seccomp.json / allowed_domains.txt / squid.conf /
# claude-settings.json from this staged tree.
#
#   --clean   remove temp_audit_package/ instead of staging
# =============================================================================
set -euo pipefail

REPO_ROOT="${WIN_AI_REPO_ROOT:-$HOME/repo}"
SANDBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ $# -ge 1 ]] || { echo "usage: $0 <profile> [--clean]" >&2; exit 1; }
profile="$1"
action="${2:-stage}"

target_workspace="$REPO_ROOT/$profile"
[[ -d "$target_workspace" ]] || { echo "no such profile workspace: $target_workspace" >&2; exit 1; }

dest="$target_workspace/temp_audit_package"

# Prior runs chmod -R a-w the tree, so restore write before rm or it errors.
if [[ -d "$dest" ]]; then
  chmod -R u+w "$dest" 2>/dev/null || true
fi

if [[ "$action" == "--clean" ]]; then
  rm -rf "$dest"
  echo "removed $dest"
  exit 0
fi

rm -rf "$dest"
mkdir -p "$dest/proxy" "$dest/scripts" "$dest/config"

cp "$SANDBOX_DIR/CLAUDE.md"                       "$dest/CLAUDE.md"
cp "$SANDBOX_DIR/Dockerfile"                      "$dest/Dockerfile"
cp "$SANDBOX_DIR/docker-compose.yml"              "$dest/docker-compose.yml"
cp "$SANDBOX_DIR/seccomp.json"                    "$dest/seccomp.json"
cp "$SANDBOX_DIR/proxy/allowed_domains.txt"       "$dest/proxy/allowed_domains.txt"
cp "$SANDBOX_DIR/proxy/squid.conf"                "$dest/proxy/squid.conf"
cp "$SANDBOX_DIR/scripts/verify-sandbox.sh"       "$dest/scripts/verify-sandbox.sh"
cp "$SANDBOX_DIR/scripts/profile.sh"              "$dest/scripts/profile.sh"
cp "$SANDBOX_DIR/config/claude-settings.json"     "$dest/config/claude-settings.json"

# Structured audit package (audit.sh + aggregate.py + probes/*) — keep tree.
cp -R "$SANDBOX_DIR/scripts/audit"                "$dest/scripts/audit"

# Internal-audit prompt is optional (the audit-sandbox skill body drives the
# workflow directly). Copy if present.
[[ -f "$SANDBOX_DIR/claude_internal_audit_wsl.md" ]] && \
  cp "$SANDBOX_DIR/claude_internal_audit_wsl.md" "$dest/claude_internal_audit.md"

chmod -R a-w "$dest"
# Restore write on directories so the agent can write /tmp-style artifacts
# (audit.sh writes nothing into the staged tree, but in case probes evolve).
find "$dest" -type d -exec chmod u+w {} +

echo "staged audit package at:"
echo "  host:      $dest"
echo "  container: /workspace/temp_audit_package/"
echo
echo "next: scripts/profile.sh $profile audit"
