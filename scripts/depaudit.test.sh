#!/usr/bin/env bash
# =============================================================================
# depaudit.test.sh — host-side regression harness for scripts/depaudit.py
# =============================================================================
# Plan 01 §10: an untested scanner is decorative. This asserts specific check
# IDs against fixture repos with known posture, so a change to one rule cannot
# silently alter another.
#
# OFFLINE BY DEFAULT. The posture fixtures need no network, which is the point —
# they run anywhere, any time, including with egress down. The OSV corpus
# (§ CORPUS below) does need network and is skipped unless --online is passed.
#
# TWO OF THESE ARE REGRESSION LOCKS FOR CHECKS THAT SHIPPED INVERTED:
#   N01  pnpm 10 BLOCKS install scripts by default; an allowlist is the HOLE.
#        The first version FAILed a repo for having no allowlist — i.e. for
#        being in the safest state — and its suggested fix would have made the
#        repo less safe to satisfy the scanner.
#   N02p `minimum-release-age` in .npmrc IS honoured. The first version rejected
#        it there, generalising from supportedArchitectures (which is genuinely
#        ignored in .npmrc). Scalar settings survive that path; nested maps do not.
# Both were found by measuring against a live pnpm, not by reasoning. If either
# assertion below starts failing, re-measure before "fixing" the test.
#
# Usage:  bash scripts/depaudit.test.sh [--online]
# =============================================================================

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DA="$HERE/depaudit.py"
FIX="$HERE/depaudit-fixtures"
ONLINE=0
[[ "${1:-}" == "--online" ]] && ONLINE=1

PASS=0
FAIL=0

# status <fixture> <check-id> -> the status string, or MISSING
status() {
  python3 "$DA" posture "$FIX/$1" --format json --fail-on never 2>/dev/null \
    | python3 -c "
import sys, json
want = sys.argv[1]
try:
    f = [x for x in json.load(sys.stdin)['findings'] if x['id'] == want]
except Exception:
    print('PARSE-ERROR'); sys.exit()
print(f[0]['status'] if f else 'MISSING')
" "$2"
}

# expect <fixture> <check-id> <expected-status> <why>
expect() {
  local got; got=$(status "$1" "$2")
  if [[ "$got" == "$3" ]]; then
    PASS=$((PASS+1)); printf "  ok   %-16s %-5s %-8s %s\n" "$1" "$2" "$3" "$4"
  else
    FAIL=$((FAIL+1)); printf "  FAIL %-16s %-5s want=%s got=%s  %s\n" "$1" "$2" "$3" "$got" "$4"
  fi
}

printf "\n-- posture fixtures (offline) --\n"

# --- full posture: the controls are configured ---
expect full-posture   N01  PASS "1 exemption (esbuild) is a short, named allowlist"
expect full-posture   N02p PASS "minimum-release-age=10080 in .npmrc IS honoured  <-- REGRESSION LOCK"
expect full-posture   N04  PASS "registry pinned"
expect full-posture   N06  PASS "lockfile committed"
expect full-posture   N11  PASS "exemption carries an adjacent reason comment"
expect full-posture   X01  PASS "CODEOWNERS covers the manifests"
expect full-posture   D01  PASS "single Node lockfile"
expect full-posture   D02  PASS "packageManager pinned"

# --- zero posture: nothing configured ---
expect zero-posture   N01  PASS "NO allowlist = strongest posture, must NOT fail  <-- REGRESSION LOCK"
expect zero-posture   N02p FAIL "no quarantine anywhere"
expect zero-posture   N04  WARN "registry not pinned"
expect zero-posture   X01  WARN "no CODEOWNERS"
expect zero-posture   D02  WARN "no packageManager pin"

# --- multi-lockfile: resolution is nondeterministic ---
expect multi-lockfile D01  FAIL "two Node lockfiles present"

# --- docs-only injection: the X04 case most scanners skip ---
expect docs-injection X04  WARN "install command lives only in AGENTS.md"
expect docs-injection X05  WARN "the named package is in no manifest — phantom instruction"

# --- python ---
expect python-uv      P03  PASS "uv.lock present"
expect python-uv      P04  PASS "exclude-newer set"
expect python-uv      P08  WARN "one dependency resolves to an sdist"
expect pip-confusion  P06  FAIL "extra-index-url is a dependency-confusion vector"
expect pip-confusion  P05  PASS "index-url pinned"

printf "\n-- lockfile enumeration (offline) --\n"
# Locks the peer-dependency-suffix bug: pnpm v9 keys look like
# `@scope/pkg@1.2.3(peer@4.5.6)`, and splitting on the LAST '@' produced the
# garbage name '@scope/pkg@1.2.3(peer'. 121 of 869 entries in a real lockfile
# hit that, and a name OSV cannot match returns no records -> reported CLEAN.
enum=$(python3 "$DA" deps "$FIX/peer-suffix" --offline --format json 2>/dev/null \
  | python3 -c "import sys,json;print('\n'.join(r['purl'] for r in json.load(sys.stdin)['results']))")
for want in "pkg:npm/@anthropic-ai/sdk@0.104.1" \
            "pkg:npm/@babel/helper-module-transforms@7.29.7" \
            "pkg:npm/lodash@4.17.21"; do
  if printf '%s\n' "$enum" | grep -qxF "$want"; then
    PASS=$((PASS+1)); printf "  ok   peer-suffix stripped: %s\n" "$want"
  else
    FAIL=$((FAIL+1)); printf "  FAIL peer-suffix NOT stripped, expected %s\n     got: %s\n" "$want" "$(printf '%s' "$enum" | tr '\n' ' ')"
  fi
done
if printf '%s\n' "$enum" | grep -q '('; then
  FAIL=$((FAIL+1)); printf "  FAIL a purl still contains '(' — peer suffix leaked into the name\n"
else
  PASS=$((PASS+1)); printf "  ok   no purl contains a peer-dependency suffix\n"
fi

printf "\n-- offline degradation --\n"
v=$(python3 "$DA" pkg npm unused-imports --offline --format json 2>/dev/null \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['results'][0]['verdict'])")
if [[ "$v" == "UNKNOWN" ]]; then
  PASS=$((PASS+1)); printf "  ok   --offline yields UNKNOWN, never a pass\n"
else
  FAIL=$((FAIL+1)); printf "  FAIL --offline yielded %s (must be UNKNOWN)\n" "$v"
fi

# --- CORPUS: needs network, opt-in ---------------------------------------
if [[ "$ONLINE" -eq 1 ]]; then
  printf "\n-- OSV corpus (--online) --\n"
  verdict() {
    python3 "$DA" pkg "$1" "$2" ${3:+"$3"} --format json 2>/dev/null \
      | python3 -c "import sys,json;print(json.load(sys.stdin)['results'][0]['verdict'])"
  }
  v=$(verdict npm unused-imports)
  if [[ "$v" == "BLOCK" ]]; then
    PASS=$((PASS+1)); printf "  ok   known-bad unused-imports -> BLOCK\n"
  else
    FAIL=$((FAIL+1)); printf "  FAIL known-bad unused-imports -> %s (want BLOCK)\n" "$v"
  fi
  # fastapi / rdflib / strawberry-graphql are the packages the reported May 2026
  # withdrawal of 157 MAL- records wrongly flagged. They are in the known-GOOD
  # corpus precisely so a withdrawn-handling regression surfaces here first.
  printf '%s\n' "npm express 4.18.0" "pypi requests 2.31.0" "npm lodash" \
                "pypi fastapi" "pypi rdflib" "pypi strawberry-graphql" \
  | while read -r eco name ver; do
      v=$(verdict "$eco" "$name" "$ver")
      if [[ "$v" == "BLOCK" ]]; then
        printf "  FAIL known-good %s/%s -> BLOCK (false positive)\n" "$eco" "$name"
      else
        printf "  ok   known-good %-22s -> %s\n" "$eco/$name" "$v"
      fi
    done
else
  printf "\n-- OSV corpus skipped (pass --online to run; needs network) --\n"
fi

printf "\n  %d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
