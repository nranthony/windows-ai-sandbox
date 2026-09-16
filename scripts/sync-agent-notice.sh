#!/usr/bin/env bash
# =============================================================================
# sync-agent-notice.sh — inject/refresh the managed sandbox-notice block
# =============================================================================
# Single source of truth: sandbox_templates/common/agent-notice.md — the one
# neutral briefing that tells an agent what fails inside the container, what is
# a human step, and how venvs, web reads and databases work. This script
# idempotently writes that content, wrapped in BEGIN/END markers, into a target
# markdown file. Re-running replaces the marker region in place, so the notice
# never drifts from the canonical block.
#
# WHERE IT IS WRITTEN. Each agent is briefed from its own GLOBAL HOME, never
# from a repo. Per profile there is exactly one target, written by profile.sh
# on `up`, `recreate`, `rebuild` and `converge`:
#     <profile>/claude-home/CLAUDE.md                  (~/.claude/CLAUDE.md)
# (agy's global rules root was measured not loaded — ADR-0015, amended.)
# A REPO NEVER CARRIES THE BLOCK. A repo's agents may not edit inside the
# markers, so a block placed in an AGENTS.md is unfixable from inside the repo
# and goes stale the moment the template moves; and a repo checked out under two
# sandboxes gets two blocks. `--strip` exists to retire the blocks that were
# placed into repos by hand before that rule; nothing automated calls it.
#
# Usage:
#   scripts/sync-agent-notice.sh <target> [<target> ...]
#   scripts/sync-agent-notice.sh --strip <target> [<target> ...]
#     <target> may be a markdown FILE or a DIRECTORY (→ <dir>/AGENTS.md).
#
# Examples:
#   scripts/sync-agent-notice.sh ~/.ai-sandbox/profiles/alpha/claude-home/CLAUDE.md
#   scripts/sync-agent-notice.sh --strip ~/repo/alpha      # → ~/repo/alpha/AGENTS.md
#
# ONE BEGIN MARKER IS WRITTEN; ANY BEGIN MARKER IS RECOGNISED. The BEGIN line
# used to name the sandbox that wrote it, which made one slot two sandboxes
# fought over: each wrote its own spelling, so syncing over the other's block
# matched nothing and APPENDED a second block. What is written is now neutral
# and fixed (BEGIN_MARK). What is RECOGNISED — for replacement and for --strip —
# is any line STARTING with BEGIN_PREFIX, because the spellings found in the
# wild are not a closed set:
#     <!-- BEGIN sandbox-notice (managed by macolima — do not edit here) -->
#     <!-- BEGIN sandbox-notice (managed by windows-ai-sandbox — do not edit here) -->
#     <!-- BEGIN sandbox-notice (hand-maintained; mirrors …        <- opens line 3,
#         …                                                           closes line 6
# The last is hand-written and wraps its comment across four lines, so matching
# whole marker LINES cannot catch it. Prefix + "skip through the END line" does,
# and it degrades safely: the region a stale block occupies is exactly what gets
# replaced or removed either way.
#
# Idempotent: if a BEGIN marker exists, the region from it to END is replaced;
# if not, the block is appended. Kept in the bash-3.2/POSIX-awk subset for
# portability to the sibling sandbox repo (no bash-4 features — no associative
# arrays, no `mapfile`).
# =============================================================================
set -euo pipefail

# Written by this script — the one neutral spelling.
BEGIN_MARK='<!-- BEGIN sandbox-notice (managed by the sandbox — do not edit here) -->'
END_MARK='<!-- END sandbox-notice -->'

# Recognised by this script: any line that STARTS with this. Contains no regex
# metacharacter, so it doubles as an anchored grep pattern and as an awk
# index()==1 test. See the header for the spellings this covers.
BEGIN_PREFIX='<!-- BEGIN sandbox-notice'

STRIP=0
if [[ "${1:-}" == "--strip" ]]; then
  STRIP=1
  shift
fi

[[ $# -ge 1 ]] || { echo "usage: $0 [--strip] <target-file-or-dir> [...]" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANON="$SCRIPT_DIR/sandbox_templates/common/agent-notice.md"

# Does the file carry a BEGIN marker of any spelling?
has_block() {
  grep -q "^$BEGIN_PREFIX" "$1"
}

# Resolve a target: a directory means its AGENTS.md.
resolve_target() {
  local t="$1"
  if [[ -d "$t" ]]; then
    printf '%s\n' "${t%/}/AGENTS.md"
  else
    printf '%s\n' "$t"
  fi
}

block=""
if [[ $STRIP -eq 0 ]]; then
  [[ -f "$CANON" ]] || { echo "sync-agent-notice: canonical block not found: $CANON" >&2; exit 1; }
  # Assemble the full block (markers + canonical content) once, in a temp file.
  # Explicit template: macOS mktemp ignores TMPDIR without one.
  block="$(mktemp "${TMPDIR:-/tmp}/agent-notice.XXXXXX")"
  trap 'rm -f "$block"' EXIT
  {
    printf '%s\n' "$BEGIN_MARK"
    cat "$CANON"
    printf '%s\n' "$END_MARK"
  } > "$block"
fi

sync_one() {
  local target
  target="$(resolve_target "$1")"

  # New file (or empty) → just drop the block in.
  # NOTE ON MODES: the create path leaves the file at the umask default (644).
  # The update and strip paths write the new content INTO the existing file
  # (`cat tmp > target`, never `mv tmp target`) so the target keeps its mode,
  # owner and inode. An earlier mv version landed every updated file at 600
  # (mktemp's mode) — harmless for the home files, wrong for a repo AGENTS.md
  # that a container reads under a different uid.
  if [[ ! -s "$target" ]]; then
    mkdir -p "$(dirname "$target")"
    cat "$block" > "$target"
    echo "created  $target"
    return
  fi

  # Existing file WITHOUT any BEGIN marker → append (blank line + block).
  if ! has_block "$target"; then
    { printf '\n'; cat "$block"; } >> "$target"
    echo "appended $target"
    return
  fi

  # Existing file WITH a marker (neutral, legacy, or a hand-written multi-line
  # one) → replace the region in place, writing the NEUTRAL begin marker
  # whichever spelling was found.
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/agent-notice.XXXXXX")"
  awk -v blockfile="$block" -v pfx="$BEGIN_PREFIX" -v end="$END_MARK" '
    function dumpblock(  line){ while ((getline line < blockfile) > 0) print line; close(blockfile) }
    !skip && index($0, pfx) == 1 { dumpblock(); skip=1; next }
    skip && index($0, end) == 1 { skip=0; next }
    skip { next }
    { print }
  ' "$target" > "$tmp"
  cat "$tmp" > "$target" && rm -f "$tmp"
  echo "updated  $target"
}

strip_one() {
  local target
  target="$(resolve_target "$1")"

  # Never create a file in strip mode.
  if [[ ! -s "$target" ]] || ! has_block "$target"; then
    echo "no block $target"
    return
  fi

  # Remove BEGIN…END plus ONE blank line immediately after END. The blocks were
  # PREPENDED under the file's `# Title` + blank line, so the blank before BEGIN
  # is the title's own spacing and must stay; the stray one is after END.
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/agent-notice.XXXXXX")"
  awk -v pfx="$BEGIN_PREFIX" -v end="$END_MARK" '
    !skip && index($0, pfx) == 1 { skip=1; next }
    skip && index($0, end) == 1 { skip=0; ateblank=1; next }
    skip { next }
    ateblank { ateblank=0; if ($0 == "") next }
    { print }
  ' "$target" > "$tmp"
  cat "$tmp" > "$target" && rm -f "$tmp"
  echo "stripped $target"
}

for t in "$@"; do
  if [[ $STRIP -eq 1 ]]; then
    strip_one "$t"
  else
    sync_one "$t"
  fi
done
