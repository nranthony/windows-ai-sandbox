#!/usr/bin/env bash
# =============================================================================
# sync-agent-notice.test.sh — behaviour lock for scripts/sync-agent-notice.sh
# =============================================================================
# Offline: no docker, no network, no profile state. Every case runs against a
# throwaway fixture file in a temp dir; nothing in the repo or in any profile is
# touched.
#
# WHAT IS LOCKED, AND WHY
# -----------------------
#   1. EVERY BEGIN SPELLING IS ONE SLOT. The BEGIN line used to name the
#      sandbox that wrote it ("managed by macolima" / "managed by
#      windows-ai-sandbox"), so a file carrying the OTHER sandbox's block fell
#      through to the append branch and ended up with TWO blocks — the failure
#      that put eight stale, unrefreshable notices into repos. The script now
#      writes ONE neutral marker and recognises ANY line starting
#      `<!-- BEGIN sandbox-notice`. Four spellings are tested separately — the
#      neutral one, the two legacy ones, and a HAND-WRITTEN one whose comment
#      WRAPS ACROSS FOUR LINES (found in two depot repos; a whole-line match
#      cannot see it, which is why detection is by prefix + "skip to END").
#      Every case asserts EXACTLY ONE BEGIN afterwards.
#
#   2. TEXT OUTSIDE THE REGION IS NEVER TOUCHED. The targets are files a human
#      or another tool also writes to (a profile's global CLAUDE.md, a repo's
#      AGENTS.md), so the sync must be surgical. Every update case compares the
#      out-of-region bytes before and after.
#
#   3. `--strip` TAKES THE BLANK AFTER END, NOT THE ONE BEFORE BEGIN. The live
#      blocks were PREPENDED under the file's `# Title` + blank line, so the
#      blank above BEGIN is the title's own spacing. Eating the wrong one welds
#      the title to the body. The fixtures are built in exactly that shape
#      (`# Title`, blank, block, blank, body) and the expected result is
#      asserted byte-for-byte.
#
#   4. `--strip` NEVER CREATES A FILE. It is run by hand over repos that may or
#      may not carry a block; creating one would be the opposite of its job.
#
# Usage:  bash scripts/sync-agent-notice.test.sh
# =============================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SYNC="$HERE/sync-agent-notice.sh"
CANON="$(cd "$HERE/.." && pwd)/sandbox_templates/common/agent-notice.md"

NEUTRAL='<!-- BEGIN sandbox-notice (managed by the sandbox — do not edit here) -->'
LEG_MAC='<!-- BEGIN sandbox-notice (managed by macolima — do not edit here) -->'
LEG_WIN='<!-- BEGIN sandbox-notice (managed by windows-ai-sandbox — do not edit here) -->'
# A hand-written BEGIN whose comment wraps across four lines, as found in the
# depot repos. Only the FIRST line carries the prefix; the other three are
# ordinary text that must be swallowed with the region.
LEG_WRAP=$'<!-- BEGIN sandbox-notice (hand-maintained; mirrors another sandbox — the\n     authoritative, fuller notice is injected by the sandbox at user-global\n     level. Update this block in the same commit as any sandbox-config change;\n     do not let it drift into a second source of truth.) -->'
END_MARK='<!-- END sandbox-notice -->'

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1  (want '$3', got '$2')"; fi; }

[ -x "$SYNC" ] || [ -f "$SYNC" ] || { printf '  FAIL script missing: %s\n' "$SYNC"; exit 1; }
[ -f "$CANON" ] || { printf '  FAIL canonical notice missing: %s\n' "$CANON"; exit 1; }

# Explicit template: Apple mktemp ignores TMPDIR without one.
T=$(mktemp -d "${TMPDIR:-/tmp}/sync-agent-notice-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

# --- helpers -----------------------------------------------------------------

# A fixture in the shape every live block was placed in: title, blank, block,
# blank, body.
mkfixture() {  # <path> <begin-marker>
  { printf '# Title\n\n'
    printf '%s\n' "$2"
    printf 'stale notice text that must not survive\n'
    printf '%s\n' "$END_MARK"
    printf '\nBody line one.\nBody line two.\n'
  } > "$1"
}

# Everything OUTSIDE any BEGIN…END region, so before/after can be compared
# without the block itself.
outside() {  # <path>
  awk -v e="$END_MARK" '
    index($0, "<!-- BEGIN sandbox-notice") == 1 { skip=1; next }
    skip && index($0, e) == 1 { skip=0; next }
    skip { next }
    { print }
  ' "$1"
}

begins()  { grep -c '^<!-- BEGIN sandbox-notice' "$1" 2>/dev/null | tr -d ' '; }
countF()  { grep -cF "$1" "$2" 2>/dev/null | tr -d ' '; }

printf '\n-- fresh target --\n'

F="$T/fresh.md"
out=$(bash "$SYNC" "$F" 2>&1)
check "a missing target is created" "${out%% *}" "created"
check "  …with exactly one BEGIN" "$(begins "$F")" "1"
check "  …and the neutral marker" "$(countF "$NEUTRAL" "$F")" "1"
{ printf '%s\n' "$NEUTRAL"; cat "$CANON"; printf '%s\n' "$END_MARK"; } > "$T/want-block"
if cmp -s "$F" "$T/want-block"; then ok "  …whose content is marker+canonical+marker"
else bad "  …whose content is marker+canonical+marker"; fi

printf '\n-- existing file, no marker --\n'

F="$T/nomarker.md"
printf '# Title\n\nBody line one.\nBody line two.\n' > "$F"
cp "$F" "$T/nomarker.before"
out=$(bash "$SYNC" "$F" 2>&1)
check "an unmarked file is appended to" "${out%% *}" "appended"
check "  …one BEGIN afterwards" "$(begins "$F")" "1"
outside "$F" > "$T/nomarker.outside"
if [ "$(head -4 "$T/nomarker.outside")" = "$(cat "$T/nomarker.before")" ]; then
  ok "  …original text intact above the block"
else bad "  …original text intact above the block"; fi

printf '\n-- replacement: each BEGIN spelling --\n'

for m in NEUTRAL MAC WIN WRAP; do
  case "$m" in
    NEUTRAL) mark="$NEUTRAL";   label="neutral" ;;
    MAC)     mark="$LEG_MAC";   label="legacy macolima" ;;
    WIN)     mark="$LEG_WIN";   label="legacy windows-ai-sandbox" ;;
    WRAP)    mark="$LEG_WRAP";  label="hand-written four-line BEGIN" ;;
  esac
  F="$T/repl-$m.md"
  mkfixture "$F" "$mark"
  outside "$F" > "$T/repl-$m.outside.before"
  out=$(bash "$SYNC" "$F" 2>&1)
  check "$label marker → updated (not appended)" "${out%% *}" "updated"
  check "  …exactly one BEGIN afterwards" "$(begins "$F")" "1"
  check "  …and it is the neutral one" "$(countF "$NEUTRAL" "$F")" "1"
  check "  …no legacy macolima marker left" "$(countF "$LEG_MAC" "$F")" "0"
  check "  …no legacy sibling marker left" "$(countF "$LEG_WIN" "$F")" "0"
  check "  …no wrapped BEGIN continuation left" "$(countF 'second source of truth' "$F")" "0"
  check "  …stale body gone" "$(countF 'stale notice text' "$F")" "0"
  check "  …canonical body present" "$(grep -c 'Repos under this workspace' "$F" | tr -d ' ')" "1"
  outside "$F" > "$T/repl-$m.outside.after"
  if cmp -s "$T/repl-$m.outside.before" "$T/repl-$m.outside.after"; then
    ok "  …text outside the region byte-identical"
  else bad "  …text outside the region byte-identical"; fi

  cp "$F" "$T/repl-$m.pass1"
  bash "$SYNC" "$F" >/dev/null 2>&1
  if cmp -s "$T/repl-$m.pass1" "$F"; then ok "  …a second sync is a no-op (idempotent)"
  else bad "  …a second sync is a no-op (idempotent)"; fi
done

printf '\n-- --strip --\n'

printf '# Title\n\nBody line one.\nBody line two.\n' > "$T/want-stripped"
for m in NEUTRAL MAC WIN WRAP; do
  case "$m" in
    NEUTRAL) mark="$NEUTRAL";   label="neutral" ;;
    MAC)     mark="$LEG_MAC";   label="legacy macolima" ;;
    WIN)     mark="$LEG_WIN";   label="legacy windows-ai-sandbox" ;;
    WRAP)    mark="$LEG_WRAP";  label="hand-written four-line BEGIN" ;;
  esac
  F="$T/strip-$m.md"
  mkfixture "$F" "$mark"
  out=$(bash "$SYNC" --strip "$F" 2>&1)
  check "--strip removes a $label block" "${out%% *}" "stripped"
  check "  …no BEGIN line left" "$(begins "$F")" "0"
  check "  …no END line left" "$(countF "$END_MARK" "$F")" "0"
  if cmp -s "$T/want-stripped" "$F"; then
    ok "  …blank after END gone, title+body byte-identical"
  else bad "  …blank after END gone, title+body byte-identical (got: $(od -c "$F" | head -3 | tr '\n' '|'))"; fi
done

F="$T/strip-none.md"
printf '# Title\n\nNo block here.\n' > "$F"
cp "$F" "$T/strip-none.before"
out=$(bash "$SYNC" --strip "$F" 2>&1)
check "--strip on a file with no block reports it" "${out% *}" "no block"
if cmp -s "$T/strip-none.before" "$F"; then ok "  …and leaves the file untouched"
else bad "  …and leaves the file untouched"; fi

F="$T/strip-absent.md"
bash "$SYNC" --strip "$F" >/dev/null 2>&1
if [ ! -e "$F" ]; then ok "--strip never creates a missing file"
else bad "--strip never creates a missing file"; fi

printf '\n-- directory argument --\n'

D="$T/repo"
mkdir -p "$D"
out=$(bash "$SYNC" "$D" 2>&1)
check "a directory arg maps to <dir>/AGENTS.md" "${out##* }" "$D/AGENTS.md"
if [ -f "$D/AGENTS.md" ]; then ok "  …and the file is written there"
else bad "  …and the file is written there"; fi
out=$(bash "$SYNC" --strip "$D" 2>&1)
check "--strip on a directory arg maps the same way" "${out##* }" "$D/AGENTS.md"
check "  …and the block is gone" "$(begins "$D/AGENTS.md")" "0"


# --- modes: update and strip keep the target's mode (a repo AGENTS.md is 644) ---
# GNU stat first: on Linux `stat -f` is FILESYSTEM status and exits 0 with a
# multi-line report, so the BSD-first order never reached the fallback and both
# mode checks failed on every Linux host (found porting from macolima, 2026-09-15).
MODEFIX="$T/mode.md"
printf '# T\n\n%s\nold\n%s\n\nbody\n' "$NEUTRAL" "$END_MARK" > "$MODEFIX"
chmod 644 "$MODEFIX"
bash "$SYNC" "$MODEFIX" >/dev/null
check "update keeps mode 644" "$(stat -c %a "$MODEFIX" 2>/dev/null || stat -f %Lp "$MODEFIX")" "644"
bash "$SYNC" --strip "$MODEFIX" >/dev/null
check "strip keeps mode 644" "$(stat -c %a "$MODEFIX" 2>/dev/null || stat -f %Lp "$MODEFIX")" "644"

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
