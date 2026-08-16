#!/usr/bin/env bash
# =============================================================================
# vendor-tools.test.sh — channel consume-path regression suite (offline)
# =============================================================================
# No docker, no network, no real channel. Builds throwaway channel roots and
# runs the REAL scripts/vendor-tools.sh against them.
#
# WHY THIS SUITE EXISTS. vendor-tools is a route by which payloads enter the
# image: the wheel bakes at build time, the skills converge into every profile
# on `up`. A bug here is not a broken build — it is unverified content inside
# the sandbox boundary, arriving through the door that is supposed to check it.
#
# THREE ASSERTIONS ARE REGRESSION LOCKS, not coverage:
#
#   * NOTHING IS COPIED WHEN ANY HASH FAILS. The gate runs over every artifact
#     before the first file moves. A per-artifact gate would leave a half-mirrored
#     tree — a half-updated image with no record of which half — and it would
#     still exit non-zero, so the failure would look handled.
#
#   * PROGRESS OUTPUT MUST NOT REACH STDOUT. `verify_all` returns the flat
#     manifest table on stdout, so a progress line written to stdout is captured
#     INTO the data. Measured during development 2026-08-15: the verified-hash
#     lines vanished from the terminal and reappeared as bogus artifact rows,
#     which the mirror loop then skipped in silence — a half-consumed channel
#     reporting success. `info` writes to stderr, and the case statements assert
#     rather than skip.
#
#   * AN UNKNOWN ARTIFACT KIND FAILS, IT DOES NOT SKIP. A kind this script has
#     not been taught is content it cannot verify. Skipping it would let a future
#     channel entry enter the image unchecked while every check stayed green.
#
# The pointer three-state rule is locked here too (unconfigured SKIPs,
# configured-but-missing FAILS, no guessed fallback) — the 2026-08-14 depot move
# turned a live wheel drift into a silent green on both existing monitors
# precisely because a guess collapsed two states into one.
#
# Usage: bash scripts/vendor-tools.test.sh
# =============================================================================
set -uo pipefail

REAL_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vendor-tools.sh"
[[ -f "$REAL_SCRIPT" ]] || { echo "cannot find vendor-tools.sh next to this test" >&2; exit 1; }

pass=0; fail=0
ok()   { printf '  \033[0;32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
check(){ if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (want '$2', got '$1')"; fi; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

REPO="$ROOT/repo"
mkdir -p "$REPO/scripts"
cp "$REAL_SCRIPT" "$REPO/scripts/vendor-tools.sh"
RUN="$REPO/scripts/vendor-tools.sh"

TPL="$REPO/sandbox_templates"
LOCK="$TPL/VENDORED.lock"

# --- fixture: a channel root -------------------------------------------------
# Hashes are COMPUTED with the same tools the script uses rather than
# hand-written, so a fixture can never claim a hash the fixture does not have.
# The stub dirhash.py is deterministic and content-sensitive; it stands in for
# the channel's own implementation, which this script invokes rather than
# reimplements.
mk_channel() { # <dir>
  local c="$1"
  mkdir -p "$c/bin" "$c/dist/wheels" "$c/dist/skills/myclickup" "$c/dist/plugins/myconv/.claude-plugin"

  cat > "$c/bin/dirhash.py" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
h = hashlib.sha256()
for p in sorted(root.rglob("*")):
    if p.is_file():
        h.update(str(p.relative_to(root)).encode())
        h.update(p.read_bytes())
print(h.hexdigest())
PY

  printf 'wheel payload v1\n'      > "$c/dist/wheels/myclickup-0.6.0-py3-none-any.whl"
  printf '# skill text\n'          > "$c/dist/skills/myclickup/SKILL.md"
  printf '{"name":"myconv"}\n'     > "$c/dist/plugins/myconv/.claude-plugin/plugin.json"
  printf 'inner\n'                 > "$c/dist/plugins/myconv/README.md"

  regen_manifest "$c"
}

# Rewrite manifest.toml from whatever the channel currently holds.
regen_manifest() { # <dir>
  local c="$1" wsha ssha tsha
  wsha="$(sha256sum "$c/dist/wheels/myclickup-0.6.0-py3-none-any.whl" | awk '{print $1}')"
  ssha="$(sha256sum "$c/dist/skills/myclickup/SKILL.md" | awk '{print $1}')"
  tsha="$(python3 "$c/bin/dirhash.py" "$c/dist/plugins/myconv")"
  cat > "$c/manifest.toml" <<EOF
schema = 1

[artifact.myclickup]
kind = "wheel+skill"
version = "0.6.0"
source_repo = "myclickup"
source_commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
wheel = "dist/wheels/myclickup-0.6.0-py3-none-any.whl"
wheel_sha256 = "$wsha"
skill = "dist/skills/myclickup/SKILL.md"
skill_sha256 = "$ssha"

[artifact.myconv]
kind = "plugin"
version = "0.3.0"
source_repo = "agentic-conventions"
source_commit = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
tree = "dist/plugins/myconv"
tree_sha256 = "$tsha"
EOF
}

reset_templates() { rm -rf "$TPL"; mkdir -p "$TPL"; }

# Run the script with a channel, capturing stdout/stderr/exit separately.
run_vt() { # <channel-or-empty> [args...]
  local chan="$1"; shift
  rm -f "$ROOT/out" "$ROOT/err"
  DEPOT_DIR="$chan" "$RUN" "$@" >"$ROOT/out" 2>"$ROOT/err"
  printf '%s' "$?"
}

CHAN="$ROOT/chan"
mk_channel "$CHAN"

printf '\nvendor-tools.test.sh\n\n'

# --- 1. the pointer three-state rule -----------------------------------------
reset_templates
check "$(run_vt "" --check)" 0 "unconfigured pointer SKIPs (exit 0)"
check "$(grep -c 'SKIP' "$ROOT/out" "$ROOT/err" | awk -F: '{s+=$2} END{print (s>0)?"y":"n"}')" y \
  "unconfigured says SKIP, not OK"

check "$(run_vt "$ROOT/nope" --check)" 1 "configured-but-missing FAILS (exit 1)"
check "$(grep -c 'absent' "$ROOT/err")" 1 "broken pointer names the absent path"

mkdir -p "$ROOT/notachannel"
check "$(run_vt "$ROOT/notachannel" --check)" 1 "a dir without manifest.toml FAILS"

# The pointer file's parser must skip a comment header. `head -n1` here read the
# comment AS the path once already, in the sibling script.
printf '# comment header\n\n%s\n' "$CHAN" > "$REPO/.depot-dir.local"
rm -f "$ROOT/out" "$ROOT/err"; ( cd "$REPO" && DEPOT_DIR= "$RUN" --dry-run ) >"$ROOT/out" 2>"$ROOT/err"
check "$?" 0 ".depot-dir.local: comment header is skipped, path is read"
rm -f "$REPO/.depot-dir.local"

# --- 2. manifest and schema guards -------------------------------------------
cp -R "$CHAN" "$ROOT/badschema"; sed -i 's/^schema = 1/schema = 2/' "$ROOT/badschema/manifest.toml"
check "$(run_vt "$ROOT/badschema" --dry-run)" 1 "an unknown manifest schema FAILS"

cp -R "$CHAN" "$ROOT/nokind"; sed -i '/^kind = "wheel+skill"/d' "$ROOT/nokind/manifest.toml"
check "$(run_vt "$ROOT/nokind" --dry-run)" 1 "an artifact with no kind FAILS"

cp -R "$CHAN" "$ROOT/newkind"; sed -i 's/^kind = "plugin"/kind = "container-image"/' "$ROOT/newkind/manifest.toml"
check "$(run_vt "$ROOT/newkind" --dry-run)" 1 "an UNKNOWN KIND fails, it does not skip  <-- LOCK"
check "$(grep -c 'unknown artifact kind' "$ROOT/err")" 1 "unknown kind says so by name"

cp -R "$CHAN" "$ROOT/nosha"; sed -i '/^wheel_sha256/d' "$ROOT/nosha/manifest.toml"
check "$(run_vt "$ROOT/nosha" --dry-run)" 1 "a missing hash field FAILS"

# --- 3. path containment ------------------------------------------------------
cp -R "$CHAN" "$ROOT/escape"
sed -i 's|^wheel = .*|wheel = "../../../etc/hostname"|' "$ROOT/escape/manifest.toml"
check "$(run_vt "$ROOT/escape" --dry-run)" 1 "a manifest path escaping the root FAILS"
check "$(grep -c 'escapes the channel root' "$ROOT/err")" 1 "traversal is named as such"

cp -R "$CHAN" "$ROOT/abspath"
sed -i 's|^skill = .*|skill = "/etc/hostname"|' "$ROOT/abspath/manifest.toml"
check "$(run_vt "$ROOT/abspath" --dry-run)" 1 "an absolute manifest path FAILS"

# --- 4. the hash gate ---------------------------------------------------------
cp -R "$CHAN" "$ROOT/tamperw"; printf 'x' >> "$ROOT/tamperw/dist/wheels/myclickup-0.6.0-py3-none-any.whl"
check "$(run_vt "$ROOT/tamperw" --dry-run)" 1 "a tampered wheel FAILS"

cp -R "$CHAN" "$ROOT/tampers"; printf 'x' >> "$ROOT/tampers/dist/skills/myclickup/SKILL.md"
check "$(run_vt "$ROOT/tampers" --dry-run)" 1 "a tampered skill FAILS"

cp -R "$CHAN" "$ROOT/tampert"; printf 'phantom\n' > "$ROOT/tampert/dist/plugins/myconv/PHANTOM.md"
check "$(run_vt "$ROOT/tampert" --dry-run)" 1 "a tampered plugin TREE FAILS (via the channel's dirhash)"

# THE LOCK: the gate must run over everything before anything is copied. myconv
# sorts after myclickup, so a per-artifact gate would already have mirrored the
# (valid) myclickup wheel before reaching the bad tree.
reset_templates
check "$(run_vt "$ROOT/tampert")" 1 "vendor aborts on the tampered tree"
check "$([[ -e "$TPL/wheels" || -e "$TPL/skills" || -e "$LOCK" ]] && echo dirty || echo clean)" clean \
  "NOTHING is copied when any hash fails  <-- LOCK"

# --- 5. stdout hygiene --------------------------------------------------------
# Progress on stdout is captured into the manifest table by command substitution.
reset_templates
run_vt "$CHAN" --dry-run >/dev/null
check "$(grep -c 'verified' "$ROOT/out")" 0 "progress never reaches stdout  <-- LOCK"
check "$(grep -c 'verified' "$ROOT/err")" 3 "all three artifacts report verified on stderr"

# --- 6. dry-run is inert ------------------------------------------------------
reset_templates
run_vt "$CHAN" --dry-run >/dev/null
check "$([[ -e "$TPL/wheels" || -e "$LOCK" ]] && echo dirty || echo clean)" clean "--dry-run copies nothing"

# --- 7. the mirror ------------------------------------------------------------
reset_templates
mkdir -p "$TPL/wheels" "$TPL/skills/myconv"
# A stale wheel from a previous version. Two wheels in this directory is a
# deliberate BUILD REFUSAL, so the old one must go before the new one lands.
printf 'old\n' > "$TPL/wheels/myclickup-0.5.0-py3-none-any.whl"
# A file upstream no longer has. delete-then-copy must remove it; a merge leaves
# phantom copies, which is the ADR-0005 failure in a different tree.
printf 'phantom\n' > "$TPL/skills/myconv/PHANTOM.md"

check "$(run_vt "$CHAN")" 0 "vendor succeeds against a valid channel"
check "$(ls "$TPL/wheels"/*.whl 2>/dev/null | wc -l)" 1 "exactly one wheel remains"
check "$([[ -e "$TPL/wheels/myclickup-0.5.0-py3-none-any.whl" ]] && echo y || echo n)" n \
  "the superseded wheel is removed, not left beside the new one"
check "$([[ -f "$TPL/skills/myclickup/SKILL.md" ]] && echo y || echo n)" y "skill lands at skills/<art>/SKILL.md"
check "$([[ -e "$TPL/skills/myconv/PHANTOM.md" ]] && echo y || echo n)" n \
  "plugin tree is delete-then-copy: an upstream deletion vanishes"
check "$([[ -f "$TPL/skills/myconv/.claude-plugin/plugin.json" ]] && echo y || echo n)" y \
  "plugin tree copies at depth"

# --- 8. the lock --------------------------------------------------------------
check "$([[ -f "$LOCK" ]] && echo y || echo n)" y "VENDORED.lock is written"
check "$(grep -vc '^#' "$LOCK")" 3 "one row per artifact component (2 for a pair, 1 for a tree)"
check "$(grep -v '^#' "$LOCK" | awk 'NF!=4' | wc -l)" 0 "every row is exactly 4 fields"
check "$(grep -v '^#' "$LOCK" | cut -d' ' -f1 | tr '\n' ',')" "myclickup.skill,myclickup.wheel,myconv.tree," \
  "rows are sorted and name the component"
check "$(grep -c '^#' "$LOCK")" 3 "the lock carries its provenance header"
# It must sit at the templates ROOT: converge_skills walks directories under
# skills/, so a lock filed there would ride into every profile.
check "$([[ -f "$TPL/VENDORED.lock" && ! -e "$TPL/skills/VENDORED.lock" ]] && echo y || echo n)" y \
  "lock sits above skills/, so convergence cannot carry it"

# --- 9. drift detection -------------------------------------------------------
check "$(run_vt "$CHAN" --check)" 0 "--check passes immediately after a vendor"

printf 'wheel payload v2\n' > "$CHAN/dist/wheels/myclickup-0.6.0-py3-none-any.whl"
regen_manifest "$CHAN"
check "$(run_vt "$CHAN" --check)" 1 "--check FAILS once the channel moves ahead of the lock"
check "$(grep -c 'DRIFT' "$ROOT/out" "$ROOT/err" | awk -F: '{s+=$2} END{print (s>0)?"y":"n"}')" y \
  "drift is reported as DRIFT, with a re-vendor instruction"

check "$(run_vt "$CHAN")" 0 "re-vendoring clears the drift"
check "$(run_vt "$CHAN" --check)" 0 "--check is green again after re-vendor"

# A lock that does not exist is "nothing vendored here yet", not drift.
rm -f "$LOCK"
check "$(run_vt "$CHAN" --check)" 0 "a missing lock SKIPs rather than failing"

# --- 10. argument handling ----------------------------------------------------
check "$(run_vt "$CHAN" --wat)" 1 "an unknown argument FAILS rather than defaulting to vendor"

printf '\n  %d passed, %d failed\n\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
