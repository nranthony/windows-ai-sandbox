#!/usr/bin/env bash
# =============================================================================
# private-names-check.sh — no real client/project names on public-repo surfaces
# =============================================================================
# This repo is PUBLIC. Profile names double as real client/project names
# (work/0007-genericise-public-identifiers). The standard is SEARCHABLE, not
# "present at all": high-visibility surfaces (README, top-level docs, scripts,
# shipped templates, compose/Dockerfile/seccomp) must carry no client names,
# case-insensitive. Archived narrative, work items, RFCs, and evidence-bearing
# uses (proxy/allowed_domains.txt's provenance comments, where the name IS the
# checkable evidence) are deliberately OUT of scope — see work/0007/spec.md's
# scope decision. No git-history rewriting either; this is a going-forward gate.
#
# The name list itself must NOT live in the tracked tree — that would
# re-introduce exactly what this checks for. Following the repo's existing
# gitignored-pointer convention (.depot-dir.local, .myclickup-dir.local,
# .conventions-dir.local — scripts/vendor-tools.sh), the list is read from a
# gitignored .private-names.local, one name per line, '#' comments and blank
# lines skipped.
#
# Two states only (AGENTS.md: "a skip is not a pass — say so"):
#   not configured (.private-names.local absent) -> loud [SKIP], exit 0
#   configured                                    -> scan, exit 0 pass / 1 fail
# There is no third "configured but missing" state: the file IS the config, so
# its absence and "not configured" are the same fact.
#
# Surfaces scanned (tracked files only, via `git ls-files`):
#   README.md ARCHITECTURE.md AGENTS.md justfile
#   scripts/ sandbox_templates/ docs/index.md
#   docker-compose*.yml Dockerfile seccomp.json
#   proxy/ EXCEPT proxy/allowed_domains.txt, whose provenance comments name a
#   workspace ID's owning account and are the deliberate keep documented in
#   work/0007/spec.md — the name there is the evidence, not a leak.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
NAMES_FILE="$REPO_ROOT/.private-names.local"

ok()   { printf '\033[0;32m[ OK ]\033[0m  private-names: %s\n' "$*"; }
skip() { printf '\033[1;35m[SKIP]\033[0m  private-names: %s\n' "$*"; }
fail() { printf '\033[0;31m[FAIL]\033[0m  private-names: %s\n' "$*" >&2; }

if [[ ! -f "$NAMES_FILE" ]]; then
  skip "no .private-names.local — nothing configured to scan for. This is" \
       "ordinary (the names are not committed); this check provides no" \
       "coverage until the owner creates it. See scripts/private-names-check.sh header."
  exit 0
fi

mapfile -t NAMES < <(awk 'NF && $0 !~ /^[[:space:]]*#/ { print }' "$NAMES_FILE" | tr -d '\r')

if [[ "${#NAMES[@]}" -eq 0 ]]; then
  skip ".private-names.local exists but has no names after comments/blanks —" \
       "nothing to scan for."
  exit 0
fi

cd "$REPO_ROOT"

mapfile -t FILES < <(
  git ls-files -- \
    README.md ARCHITECTURE.md AGENTS.md justfile \
    'scripts/**' 'sandbox_templates/**' docs/index.md \
    'docker-compose*.yml' Dockerfile seccomp.json \
    'proxy/**' \
  | grep -v '^proxy/allowed_domains\.txt$'
)

pattern="$(printf '%s\n' "${NAMES[@]}" | paste -sd '|' -)"

failed=0
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || continue
  hits="$(grep -nEi -- "$pattern" "$f" 2>/dev/null || true)"
  if [[ -n "$hits" ]]; then
    failed=1
    fail "$f carries a private name:"
    while IFS= read -r line; do
      printf '         %s\n' "$line" >&2
    done <<<"$hits"
  fi
done

if [[ "$failed" -eq 1 ]]; then
  fail "private name(s) found on a public-repo high-visibility surface (see" \
       "scripts/private-names-check.sh header for scope and the deliberate keeps)."
  exit 1
fi

ok "no private names found across ${#FILES[@]} scanned file(s), ${#NAMES[@]} name(s) checked."
exit 0
