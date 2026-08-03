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

# status_path <abs-path> <check-id> — same as status() for a tree outside
# depaudit-fixtures/ (used where a case needs a file the fixture dir must not
# carry permanently, e.g. a child rc that would change other assertions).
status_path() {
  python3 "$DA" posture "$1" --format json --fail-on never 2>/dev/null \
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

# expect_path <abs-path> <check-id> <expected-status> <why>
expect_path() {
  local got; got=$(status_path "$1" "$2")
  if [[ "$got" == "$3" ]]; then
    PASS=$((PASS+1)); printf "  ok   %-16s %-5s %-8s %s\n" "(tmp)" "$2" "$3" "$4"
  else
    FAIL=$((FAIL+1)); printf "  FAIL %-16s %-5s want=%s got=%s  %s\n" "(tmp)" "$2" "$3" "$got" "$4"
  fi
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

# --- monorepo with a child that switches the age gate off for itself ---
# The root is healthy (10080 in pnpm-workspace.yaml), so every root-scoped check
# reports clean — which is exactly why N03 exists. A malformed value outranks a
# merely-weak one because it fails CLOSED and presents as a broken registry.
expect monorepo-weak-child N02p PASS "root quarantine is strong — the point is that this is not enough"
expect monorepo-weak-child N03  FAIL "a child .npmrc/pnpm-workspace.yaml weakens or breaks the gate"
expect monorepo-weak-child D03  WARN "children exist and were NOT covered by this root-scoped scan"

# N03 must stay silent on a child with no override — it inherits the global
# window, which is the wanted state. A finding there would fire on every healthy
# monorepo member, and a permanently-firing check is furniture (see G10).
CLEANFIX="$(mktemp -d "${TMPDIR:-/tmp}/n03clean.XXXXXX")"
mkdir -p "$CLEANFIX/packages/inherits"
printf '{ "name": "r", "packageManager": "pnpm@10.34.5" }\n' > "$CLEANFIX/package.json"
printf "lockfileVersion: '9.0'\n"                            > "$CLEANFIX/pnpm-lock.yaml"
printf 'minimumReleaseAge: 10080\n'                          > "$CLEANFIX/pnpm-workspace.yaml"
printf '{ "name": "inherits" }\n' > "$CLEANFIX/packages/inherits/package.json"
got="$(cd "$HERE/.." && python3 scripts/depaudit.py posture "$CLEANFIX" --format json --fail-on never \
        | python3 -c 'import json,sys; print(",".join(f["id"] for f in json.load(sys.stdin)["findings"]))')"
if [[ ",$got," == *",N03,"* ]]; then
  bad "N03 silent when a child has no override" "no N03 finding" "N03 present"
else
  ok "N03 silent when a child has no override (inheritance is the wanted state)"
fi
# ...but a child that DOES override, at full strength, is a PASS not silence.
printf 'minimum-release-age=10080\n' > "$CLEANFIX/packages/inherits/.npmrc"
expect_path "$CLEANFIX" N03 PASS "a child override at full strength passes"
rm -rf "$CLEANFIX"

# --- docs-only injection: the X04 case most scanners skip ---
expect docs-injection X04  WARN "install command lives only in AGENTS.md"
expect docs-injection X05  WARN "the named package is in no manifest — phantom instruction"

# --- nested docs: a per-app README is read by an agent working in that dir ---
# Both hits are below apps/, which the old root+docs/ globs could not see.
expect nested-docs    X04  WARN "install commands in apps/*/README.md are found"
expect nested-docs    X05  WARN "the undeclared name is a phantom"

# X05 must read CHILD manifests too, or every child-declared package becomes a
# false phantom — worse than a missed one, since it sends someone hunting for an
# injection that is not there. apps/api declares express in its OWN package.json.
detail="$(python3 "$DA" posture "$FIX/nested-docs" --format json --fail-on never \
          | python3 -c 'import sys,json; print(next((f["detail"] for f in json.load(sys.stdin)["findings"] if f["id"]=="X05"), ""))')"
if [[ "$detail" == *left-pad-utils-helper* && "$detail" != *express* ]]; then
  PASS=$((PASS+1)); printf "  ok   %-16s %-5s %-8s %s\n" "nested-docs" "X05" "detail" \
    "child-declared express is NOT a phantom  <-- FALSE-PHANTOM LOCK"
else
  FAIL=$((FAIL+1)); printf "  FAIL %-16s %-5s want=only left-pad-utils-helper got=%s\n" \
    "nested-docs" "X05" "$detail"
fi

# X04/X05 must not report things that are not package names. All three of these
# were found firing on real workspaces once the scan widened beyond the repo root,
# and each produced a phantom: a flag, a shell operator, and an extras form whose
# plain name IS declared. A false phantom sends someone hunting for an injection
# that does not exist, so these are locks, not niceties.
NOISEFIX="$(mktemp -d "${TMPDIR:-/tmp}/x04noise.XXXXXX")"
mkdir -p "$NOISEFIX/.venv-linux/lib/python3.12/site-packages/thirdparty"
cat > "$NOISEFIX/pyproject.toml" <<'EOF'
[project]
name = "root"
dependencies = ["paperbridge[zotero,bibtex] @ git+https://example.invalid/p.git"]
EOF
cat > "$NOISEFIX/AGENTS.md" <<'EOF'
Install with `pnpm install --frozen-lockfile` or `npm install -g`.
Build with `npm install && npm run build`.
Extras form: `pip install paperbridge[zotero,bibtex]`.
EOF
printf 'Docs for another project: `pip install babel`\n' \
  > "$NOISEFIX/.venv-linux/lib/python3.12/site-packages/thirdparty/README.md"
noise="$(python3 "$DA" posture "$NOISEFIX" --format json --fail-on never \
         | python3 -c 'import sys,json
d=json.load(sys.stdin)["findings"]
x4=next((f["detail"] for f in d if f["id"]=="X04"), "")
x5=next((f["detail"] for f in d if f["id"]=="X05"), "")
print(x4+" || "+x5)')"
for probe in "frozen-lockfile:a lockfile install names no package" \
             "&&:a shell operator is not a package name" \
             "babel:third-party docs inside a .venv-linux/site-packages tree" \
             "paperbridge:an extras form whose plain name is declared"; do
  needle="${probe%%:*}"; why="${probe#*:}"
  if [[ "$noise" == *"$needle"* ]]; then
    FAIL=$((FAIL+1)); printf "  FAIL %-16s %-5s %s (found %s)\n" "(noise)" "X04/5" "$why" "$needle"
  else
    PASS=$((PASS+1)); printf "  ok   %-16s %-5s %-8s %s\n" "(noise)" "X04/5" "excluded" "$why"
  fi
done
rm -rf "$NOISEFIX"

# --- python ---
expect python-uv      P03  PASS "uv.lock present"
expect python-uv      P04  PASS "exclude-newer set"
expect python-uv      P08  WARN "one dependency has NO wheel and must build from source"
expect pip-confusion  P06  FAIL "extra-index-url is a dependency-confusion vector"
expect pip-confusion  P05  PASS "index-url pinned"

# REGRESSION LOCK. P08 must count sdist-ONLY packages, not every package that
# publishes an sdist alongside wheels. The fixture's `idna` has both; if it is
# named in the detail string the check has reverted to `"sdist" in p`, which
# over-reported by ~87x on real lockfiles and produced the number that gated T23.
p08_detail=$(python3 "$DA" posture "$FIX/python-uv" --format json --fail-on never 2>/dev/null \
  | python3 -c "
import sys, json
f=[x for x in json.load(sys.stdin)['findings'] if x['id']=='P08']
print(f[0].get('detail','') if f else '')" )
if [[ "$p08_detail" == *idna* ]]; then
  FAIL=$((FAIL+1)); printf "  FAIL P08 counted a package that HAS wheels (idna)  <-- the 87x over-report is back\n"
elif [[ "$p08_detail" == *requests* ]]; then
  PASS=$((PASS+1)); printf "  ok   P08 counts sdist-ONLY, ignores sdist+wheels  <-- REGRESSION LOCK\n"
else
  FAIL=$((FAIL+1)); printf "  FAIL P08 detail named neither requests nor idna: %s\n" "$p08_detail"
fi

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
