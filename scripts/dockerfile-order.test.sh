#!/usr/bin/env bash
# =============================================================================
# dockerfile-order.test.sh — the build-layer ORDER is load-bearing
# =============================================================================
# Four separate comments in the Dockerfile each claim a position, and together
# they form one chain that must hold:
#
#   beads  <  claude/agy install  <  npmrc (Gate 2)  <  uv+pip (Gate 3)
#
# Why each link matters:
#
#   beads BEFORE the AI-CLI refresh tail — `--refresh-ai` must not silently bump
#     bd. The cache-buster ARG sits at the top of the tail, so everything below it
#     re-executes on every refresh; beads has to stay above that line.
#
#   Gate 2 (npmrc) AFTER the claude/agy install — THIS IS THE ONE THAT BREAKS
#     BUILDS. `min-release-age` applies to `npm install` at BUILD time too, so
#     writing it earlier makes `@anthropic-ai/claude-code@latest` unresolvable
#     whenever the newest release is inside the quarantine window. The failure is
#     intermittent by nature: it depends on when upstream last published, so it
#     passes locally and breaks a week later. Worse, because `--refresh-ai`
#     re-runs the CLI install every time, a mis-order surfaces on a routine
#     version bump rather than only on a cold rebuild.
#
#   Gate 3 (uv/pip) LAST — it is config-only and has no build-time dependency of
#     its own, so it belongs at the end where a change rebuilds nothing above it.
#
# Anchored on STRINGS, never line numbers: line numbers drift on every edit above
# them, and a test that needs updating for unrelated edits gets updated
# carelessly. If a deliberate rename makes an anchor vanish, this fails with
# "0 occurrences" and names the anchor to fix — loudly, which is the point.
#
# Fully offline. No docker, no network, no build.
#
# Usage:  bash scripts/dockerfile-order.test.sh
# =============================================================================

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DF="$HERE/../Dockerfile"
[[ -f "$DF" ]] || { echo "missing $DF" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  ok   %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  FAIL %s\n       %s\n" "$1" "$2"; }

# The chain, in required order. Each entry is "label|anchor string".
ANCHORS=(
  "beads install|raw.githubusercontent.com/gastownhall/beads"
  "AI-CLI refresh boundary|ARG AI_CLI_REFRESH"
  "claude/agy install|npm install -g --allow-scripts=@anthropic-ai/claude-code"
  "Gate 2 npmrc write|> /usr/etc/npmrc"
  "Gate 3 uv write|> /etc/uv/uv.toml"
  "Gate 3 pip write|> /etc/pip.conf"
)

echo "-- Dockerfile layer order --"

# Each anchor must appear EXACTLY once. Two occurrences make "the line number of
# the anchor" ambiguous and would let a duplicated block reorder itself unseen.
declare -a LINES=() LABELS=()
for entry in "${ANCHORS[@]}"; do
  label="${entry%%|*}"; anchor="${entry#*|}"
  n="$(grep -cF -- "$anchor" "$DF")"
  if [[ "$n" -eq 1 ]]; then
    ok "anchor present exactly once: $label"
    LINES+=("$(grep -nF -- "$anchor" "$DF" | cut -d: -f1)")
    LABELS+=("$label")
  else
    bad "anchor '$label' occurs $n times (want 1)" \
        "string: $anchor
       If this was renamed deliberately, update ANCHORS in this file. If it
       vanished, the layer it guards may have been removed — check the ordering
       comments in the Dockerfile before 'fixing' the test."
  fi
done

# Strictly increasing line numbers = the chain holds.
if [[ "${#LINES[@]}" -eq "${#ANCHORS[@]}" ]]; then
  order_ok=1
  for (( i=1; i<${#LINES[@]}; i++ )); do
    if (( LINES[i] <= LINES[i-1] )); then
      order_ok=0
      bad "layer order violated: '${LABELS[i]}' (line ${LINES[i]}) must come AFTER '${LABELS[i-1]}' (line ${LINES[i-1]})" \
          "See the ordering comments in the Dockerfile. The link most likely to
       break a build is Gate 2 after the claude/agy install: min-release-age
       applies at BUILD time, so writing it earlier makes
       @anthropic-ai/claude-code@latest unresolvable whenever the newest release
       is inside the quarantine window — an intermittent, self-inflicted break."
    fi
  done
  (( order_ok )) && ok "chain holds: $(printf '%s ' "${LINES[@]}" | sed 's/ $//' | tr ' ' '<')"
else
  bad "cannot check order — an anchor is missing" "resolve the anchor failures above first"
fi

# The Gate 2 layer self-checks inside its own RUN. Cheap to assert, and it is
# what makes a mis-order fail at build time rather than at first agent install.
if grep -qF 'npm config get min-release-age' "$DF"; then
  ok "Gate 2 layer verifies its own write in-layer (npm config get)"
else
  bad "Gate 2 layer no longer self-checks" \
      "the RUN that writes /usr/etc/npmrc should end with an assertion, so a
       broken write fails the build instead of silently disabling the age gate"
fi

printf "\n  %d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
