#!/usr/bin/env bash
# =============================================================================
# sync-agent-notice.sh — inject/refresh the managed sandbox-notice block
# =============================================================================
# Single source of truth: sandbox_templates/common/agent-notice.md. This script
# idempotently writes that content, wrapped in BEGIN/END markers, into one or
# more target markdown files (a repo's AGENTS.md, or a profile's global
# claude-home/CLAUDE.md). Re-running replaces the marker region in place, so the
# notice never drifts from the canonical block.
#
# Usage:
#   scripts/sync-agent-notice.sh <target> [<target> ...]
#     <target> may be a markdown FILE or a DIRECTORY (→ <dir>/AGENTS.md).
#
# Examples:
#   scripts/sync-agent-notice.sh ~/repo/alpha            # → ~/repo/alpha/AGENTS.md
#   scripts/sync-agent-notice.sh ~/repo/*/               # all workspaces at once
#   scripts/sync-agent-notice.sh ~/.ai-sandbox/profiles/alpha/claude-home/CLAUDE.md
#
# Idempotent: if the markers exist, the region between them is replaced; if not,
# the block is appended. Kept in the bash-3.2/POSIX-awk subset for portability
# to the sibling macolima repo (no bash-4 features).
# =============================================================================
set -euo pipefail

BEGIN_MARK='<!-- BEGIN sandbox-notice (managed by windows-ai-sandbox — do not edit here) -->'
END_MARK='<!-- END sandbox-notice -->'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANON="$SCRIPT_DIR/sandbox_templates/common/agent-notice.md"

[[ -f "$CANON" ]] || { echo "sync-agent-notice: canonical block not found: $CANON" >&2; exit 1; }
[[ $# -ge 1 ]] || { echo "usage: $0 <target-file-or-dir> [...]" >&2; exit 2; }

# Assemble the full block (markers + canonical content) once, in a temp file.
block="$(mktemp)"
trap 'rm -f "$block"' EXIT
{
  printf '%s\n' "$BEGIN_MARK"
  cat "$CANON"
  printf '%s\n' "$END_MARK"
} > "$block"

sync_one() {
  local target="$1"

  # Directory → its AGENTS.md.
  if [[ -d "$target" ]]; then
    target="${target%/}/AGENTS.md"
  fi

  # New file (or empty) → just drop the block in.
  if [[ ! -s "$target" ]]; then
    mkdir -p "$(dirname "$target")"
    cat "$block" > "$target"
    echo "created  $target"
    return
  fi

  # Existing file WITHOUT the marker → append (blank line + block).
  if ! grep -qF "$BEGIN_MARK" "$target"; then
    { printf '\n'; cat "$block"; } >> "$target"
    echo "appended $target"
    return
  fi

  # Existing file WITH the marker → replace the region in place.
  local tmp
  tmp="$(mktemp)"
  awk -v blockfile="$block" -v beg="$BEGIN_MARK" -v end="$END_MARK" '
    function dumpblock(  line){ while ((getline line < blockfile) > 0) print line; close(blockfile) }
    index($0, beg) == 1 { dumpblock(); skip=1; next }
    index($0, end) == 1 { skip=0; next }
    skip { next }
    { print }
  ' "$target" > "$tmp"
  mv "$tmp" "$target"
  echo "updated  $target"
}

for t in "$@"; do
  sync_one "$t"
done
