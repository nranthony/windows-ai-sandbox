#!/usr/bin/env bash
# =============================================================================
# workspace-scan.test.sh — offline regression harness for scripts/workspace-scan.py
# =============================================================================
# Builds throwaway profile + host-only trees of real git repos in a temp dir
# (committed fixtures can't be nested git repos), scans them, and asserts
# specific finding IDs, so a change to one check cannot silently alter another.
#
# THREE ASSERTIONS ARE LOCKS FOR TRAPS FOUND WHILE WRITING THE SCANNER:
#   * An existing venv carries its own `.gitignore` = `*`, and
#     `git check-ignore .venv-sandbox/` matches THAT file — a repo with no
#     `.venv*/` rule passed. `bad` has exactly that shape and must still report
#     NO-VENV-SANDBOX-IGNORE.
#   * An ask fence of five explicit spellings with no `python3` form looked
#     complete and was not: `python3 x.py` fell through to the sandbox's broad
#     `python3:*` allow. `bad` must report ASK-GAP naming `python3`.
#   * `--out` into a tracked path must refuse (exit 2): the report names every
#     repo in every profile, and this repo is public.
#
# Usage:  bash scripts/workspace-scan.test.sh
# =============================================================================

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WS="$HERE/workspace-scan.py"
# Explicit template: Apple mktemp ignores TMPDIR without one.
T=$(mktemp -d "${TMPDIR:-/tmp}/workspace-scan-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

g() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}" >/dev/null 2>&1; }
mkrepo() { mkdir -p "$1" && git init -q "$1"; }
commit() { g "$1" add -A && g "$1" commit -qm fixture; }
fakevenv() {  # <dir> <home> [shebang-interpreter]
  mkdir -p "$1/bin" "$1/lib/python3.12/site-packages"
  printf 'home = %s\nversion_info = 3.12.3\n' "$2" > "$1/pyvenv.cfg"
  printf '*\n' > "$1/.gitignore"              # what uv writes into every venv
  if [[ -n "${3:-}" ]]; then
    printf '#!%s\nimport sys\n' "$3" > "$1/bin/pytest"
  fi
}

PROFILES="$T/profiles"; ROOT="$T/repo"; HOSTROOT="$T/hostonly"
mkdir -p "$PROFILES/p1" "$ROOT/p1" "$HOSTROOT"

# --- good: every convention in place -----------------------------------------
R="$ROOT/p1/good"; mkrepo "$R"
printf '# agents\n' > "$R/AGENTS.md"
printf '# CLAUDE.md\n\n<!-- GENERATED -->\n\n@AGENTS.md\n' > "$R/CLAUDE.md"
printf '.venv*/\n*.local\n*.local.*\n!*.local.example*\n' > "$R/.gitignore"
printf '[project]\nname = "good"\n' > "$R/pyproject.toml"
mkdir -p "$R/config"; printf 'key: example\n' > "$R/config/hub.local.example.yaml"   # sanctioned, committed
printf '3.12\n' > "$R/.python-version"
mkdir -p "$R/scripts" "$R/.claude"; printf 'print(1)\n' > "$R/scripts/x.py"
cat > "$R/.claude/settings.json" <<'EOF'
{"permissions": {
  "allow": ["Bash(uv run pytest:*)"],
  "ask": ["Bash(python*scripts/x.py*)", "Bash(uv run *scripts/x.py*)",
          "Bash(.venv*/bin/python*scripts/x.py*)", "Bash(./.venv*/bin/python*scripts/x.py*)"]}}
EOF
# This machine's accumulated approvals (gitignored by *.local.*): host paths and
# venv paths here are hygiene, not a defect — must stay INFO.
printf '{"permissions": {"allow": ["Bash(ls /Volumes/X/y:*)", "Bash(.venv/bin/pytest:*)"]}}\n' \
  > "$R/.claude/settings.local.json"
# History and non-project venvs are not findings.
mkdir -p "$R/docs/adr" "$R/.devcontainer"
printf 'Rejected: `.venv-linux` for the sandbox.\n' > "$R/docs/adr/0001-x.md"
printf '{"python.defaultInterpreterPath": "/root/.venv/bin/python"}\n' > "$R/.devcontainer/devcontainer.json"
commit "$R"

# --- bad: every failure shape --------------------------------------------------
R="$ROOT/p1/bad"; mkrepo "$R"
printf '# a CLAUDE.md with real content and no AGENTS.md\nRules here.\nMore.\nEven more.\n' > "$R/CLAUDE.md"
printf '.venv\n' > "$R/.gitignore"
printf '[project]\nname = "bad"\n' > "$R/pyproject.toml"
printf 'venv := if os() == "macos" { ".venv" } else { ".venv-linux" }\n' > "$R/justfile"
printf 'x\n' > "$R/machine.local"
printf '#!/bin/sh\n.venv/bin/python scripts/x.py\n' > "$R/run.sh"
printf 'Run `.venv/bin/python scripts/x.py`, or in the container `.venv-linux/bin/python`.\n' > "$R/README.md"
mkdir -p "$R/scripts" "$R/.claude"; printf 'print(1)\n' > "$R/scripts/x.py"
cat > "$R/.claude/settings.json" <<'EOF'
{"permissions": {
  "allow": ["Bash(.venv/bin/pytest tests/ -q)", "Bash(.venv-linux/bin/ruff check *)"],
  "ask": ["Bash(python scripts/x.py:*)", "Bash(uv run python scripts/x.py:*)",
          "Bash(uv run scripts/x.py:*)", "Bash(.venv/bin/python scripts/x.py:*)",
          "Bash(.venv-sandbox/bin/python scripts/x.py:*)"]}}
EOF
fakevenv "$R/.venv"         /opt/uv/python/cpython-3.12-linux-aarch64-gnu/bin
fakevenv "$R/.venv-linux"   /opt/uv/python/cpython-3.12-linux-aarch64-gnu/bin
fakevenv "$R/.venv-sandbox" /opt/uv/python/cpython-3.12-linux-aarch64-gnu/bin
commit "$R"

# --- slots: a host-built venv in the sandbox's slot (shebang is the evidence) -
R="$ROOT/p1/slots"; mkrepo "$R"
printf '# a\n' > "$R/AGENTS.md"; printf '@AGENTS.md\n' > "$R/CLAUDE.md"
printf '.venv*/\n*.local\n*.local.*\n' > "$R/.gitignore"
fakevenv "$R/.venv-sandbox" /usr/bin /Volumes/X/repo/p1/slots/.venv-sandbox/bin/python
commit "$R"

# --- nested: an AGENTS.md below the root without a stub; archives excluded ----
R="$ROOT/p1/nested"; mkrepo "$R"
printf '# a\n' > "$R/AGENTS.md"; printf '@AGENTS.md\n' > "$R/CLAUDE.md"
printf '*.local\n*.local.*\n' > "$R/.gitignore"
mkdir -p "$R/sub" "$R/work/archive/old" "$R/templates"
printf '# sub\n' > "$R/sub/AGENTS.md"
printf '# old\n' > "$R/work/archive/old/AGENTS.md"
printf '# stamped into other repos\n' > "$R/templates/AGENTS.md"
commit "$R"

# --- notice: a sandbox-notice block inside a repo (neutral marker, root) ------
R="$ROOT/p1/notice"; mkrepo "$R"
cat > "$R/AGENTS.md" <<'EOF'
# a

<!-- BEGIN sandbox-notice (managed by the sandbox — do not edit here) -->
You are running inside a sandbox.
<!-- END sandbox-notice -->
EOF
printf '@AGENTS.md\n' > "$R/CLAUDE.md"
printf '*.local\n*.local.*\n' > "$R/.gitignore"; commit "$R"

# --- notice-nested: the sibling's legacy marker in a tracked nested GEMINI.md -
# GEMINI.md is agy's other name for a rules file, so the notice check enumerates
# it — even though check_agents' AGENTS-source/CLAUDE-stub pair (0009) does not.
R="$ROOT/p1/notice-nested"; mkrepo "$R"
printf '# a\n' > "$R/AGENTS.md"; printf '@AGENTS.md\n' > "$R/CLAUDE.md"
printf '*.local\n*.local.*\n' > "$R/.gitignore"
mkdir -p "$R/sub" "$R/work/archive/old"
cat > "$R/sub/GEMINI.md" <<'EOF'
# sub

<!-- BEGIN sandbox-notice (managed by windows-ai-sandbox — do not edit here) -->
stale
<!-- END sandbox-notice -->
EOF
cat > "$R/work/archive/old/GEMINI.md" <<'EOF'
<!-- BEGIN sandbox-notice (managed by macolima — do not edit here) -->
history, not live guidance
<!-- END sandbox-notice -->
EOF
commit "$R"

# --- CLAUDE.md shapes the docs accept as a stub (code.claude.com/docs/en/memory)
# An inline import is a stub ("See @AGENTS.md for …"); a symlink to AGENTS.md is
# the other documented way; an import inside a code span is NOT an import.
R="$ROOT/p1/inline"; mkrepo "$R"
printf '# a\n' > "$R/AGENTS.md"
printf 'See @AGENTS.md for all project instructions, conventions, and commands.\n' > "$R/CLAUDE.md"
printf '*.local\n*.local.*\n' > "$R/.gitignore"; commit "$R"
R="$ROOT/p1/symlinked"; mkrepo "$R"
printf '# a\n' > "$R/AGENTS.md"; ln -s AGENTS.md "$R/CLAUDE.md"
printf '*.local\n*.local.*\n' > "$R/.gitignore"; commit "$R"
R="$ROOT/p1/spanonly"; mkrepo "$R"
printf '# a\n' > "$R/AGENTS.md"
printf 'Write `@AGENTS.md` to import.\nRule one.\nRule two.\nRule three.\n' > "$R/CLAUDE.md"
printf '*.local\n*.local.*\n' > "$R/.gitignore"; commit "$R"

# --- parent/member: a channel repo holding a gitignored nested checkout -------
# The member's venv must be reported once, by the member — not again by the
# parent (measured on the first real run: depot/ double-reported myclickup/.venv).
R="$ROOT/p1/parent"; mkrepo "$R"
printf '# a\n' > "$R/AGENTS.md"; printf '@AGENTS.md\n' > "$R/CLAUDE.md"
printf 'member/\n*.local\n*.local.*\n' > "$R/.gitignore"
commit "$R"
M="$R/member"; mkrepo "$M"
printf '# a\n' > "$M/AGENTS.md"; printf '@AGENTS.md\n' > "$M/CLAUDE.md"
printf '.venv*/\n*.local\n*.local.*\n' > "$M/.gitignore"
fakevenv "$M/.venv" /opt/uv/python/cpython-3.12-linux-aarch64-gnu/bin
commit "$M"

# --- host-only root: a host path in a rule is informational there ------------
R="$HOSTROOT/hostrepo"; mkrepo "$R"
printf '# a\n' > "$R/AGENTS.md"; printf '@AGENTS.md\n' > "$R/CLAUDE.md"
printf '*.local\n*.local.*\n' > "$R/.gitignore"
mkdir -p "$R/.claude"
printf '{"permissions": {"allow": ["Bash(/Users/someone/bin/tool:*)"]}}\n' > "$R/.claude/settings.json"
commit "$R"

JSON="$T/out.json"
python3 "$WS" --profiles-dir "$PROFILES" --workspaces-root "$ROOT" --also "$HOSTROOT" \
  --format json > "$JSON" 2>"$T/err" || { bad "scanner ran (see $T/err)"; cat "$T/err"; }

# has <rel> <ID> [level] -> prints yes|no
has() {
  python3 - "$JSON" "$1" "$2" "${3:-}" <<'EOF'
import json, sys
data, rel, fid, lvl = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3], sys.argv[4]
hit = [f for r in data["repos"] if r["rel"] == rel for f in r["findings"]
       if f["id"] == fid and (not lvl or f["level"] == lvl)]
print("yes" if hit else "no")
EOF
}
expect()  { [[ "$(has "$1" "$2" "${3:-}")" == yes ]] && ok "$1: $2 ${3:-}" || bad "$1: expected $2 ${3:-}"; }
refute()  { [[ "$(has "$1" "$2")" == no ]] && ok "$1: no $2" || bad "$1: unexpected $2"; }

echo "== good repo: no ACTION findings"
n=$(python3 -c "
import json,sys
d=json.load(open('$JSON'))
print(sum(1 for r in d['repos'] if r['rel']=='good' for f in r['findings'] if f['level']!='INFO'))")
[[ "$n" == 0 ]] && ok "good: zero ACTION/UNKNOWN" || bad "good: $n ACTION/UNKNOWN findings"

echo "== bad repo"
for id in CLAUDE-ONLY NO-VENV-SANDBOX-IGNORE NO-PYTHON-VERSION VENV-PATH-ALLOW ASK-GAP \
          OS-VENV-SELECT HARDCODED-VENV-LINUX TRACKED-LOCAL NO-LOCAL-IGNORE \
          SANDBOX-VENV-IN-HOST-SLOT LEGACY-VENV-SLOT; do
  expect bad "$id" ACTION
done
refute bad NO-VENV-IGNORE
gap=$(python3 -c "
import json
d=json.load(open('$JSON'))
print(' | '.join(e for r in d['repos'] if r['rel']=='bad' for f in r['findings'] if f['id']=='ASK-GAP' for e in f['evidence']))")
[[ "$gap" == *"python3 scripts/x.py"* ]] && ok "bad: ASK-GAP names the python3 spelling" \
  || bad "bad: ASK-GAP should name 'python3 scripts/x.py' (got: $gap)"
[[ "$gap" != *"| python scripts/x.py"* && "$gap" != "python scripts/x.py"* ]] \
  && ok "bad: covered 'python scripts/x.py' not reported" || bad "bad: covered spelling reported as a gap"

expect bad VENV-PATH-IN-CODE ACTION
expect bad DOC-VENV-LINUX ACTION
code_ev=$(python3 -c "
import json
d=json.load(open('$JSON'))
print(' | '.join(e for r in d['repos'] if r['rel']=='bad' for f in r['findings'] if f['id']=='VENV-PATH-IN-CODE' for e in f['evidence']))")
[[ "$code_ev" == *run.sh* && "$code_ev" != *README* ]] && ok "bad: executed file is code, README is not" \
  || bad "bad: VENV-PATH-IN-CODE evidence wrong (got: $code_ev)"
linux_ev=$(python3 -c "
import json
d=json.load(open('$JSON'))
print(' | '.join(e for r in d['repos'] if r['rel']=='bad' for f in r['findings'] if f['id']=='HARDCODED-VENV-LINUX' for e in f['evidence']))")
[[ "$linux_ev" == *".venv-linux/bin/ruff"* ]] && ok "bad: shared .venv-linux allow rule counts toward the gate" \
  || bad "bad: .venv-linux allow rule missing from HARDCODED-VENV-LINUX (got: $linux_ev)"

echo "== good repo: false-positive locks"
refute good TRACKED-LOCAL
expect good HOST-PATH INFO
expect good VENV-PATH-ALLOW INFO
refute good DOC-VENV-LINUX
refute good VENV-PATH-IN-CODE

echo "== slots / nested / parent-member / host-only"
expect slots HOST-VENV-IN-SANDBOX-SLOT ACTION
refute slots NO-VENV-SANDBOX-IGNORE
expect nested NESTED-AGENTS-NO-STUB ACTION
nested_hits=$(python3 -c "
import json
d=json.load(open('$JSON'))
print(' '.join(e for r in d['repos'] if r['rel']=='nested' for f in r['findings'] for e in f['evidence']))")
[[ "$nested_hits" != *archive* ]] && ok "nested: archive/ excluded" || bad "nested: archive/ reported"
[[ "$nested_hits" != *templates* ]] && ok "nested: templates/ excluded" || bad "nested: templates/ reported"
refute inline BOTH-SUBSTANTIVE
refute symlinked BOTH-SUBSTANTIVE
expect spanonly BOTH-SUBSTANTIVE ACTION
expect parent/member SANDBOX-VENV-IN-HOST-SLOT ACTION
refute parent SANDBOX-VENV-IN-HOST-SLOT
expect hostrepo HOST-PATH INFO

echo "== sandbox notice in a repo"
expect notice NOTICE-IN-REPO ACTION
expect notice-nested NOTICE-IN-REPO ACTION
refute good NOTICE-IN-REPO
notice_ev=$(python3 -c "
import json
d=json.load(open('$JSON'))
print(' | '.join(e for r in d['repos'] if r['rel']=='notice' for f in r['findings'] if f['id']=='NOTICE-IN-REPO' for e in f['evidence']))")
[[ "$notice_ev" == "AGENTS.md:3: <!-- BEGIN sandbox-notice"* ]] \
  && ok "notice: evidence is <relpath>:<line>: <marker>" \
  || bad "notice: evidence wrong (got: $notice_ev)"
nested_notice_ev=$(python3 -c "
import json
d=json.load(open('$JSON'))
print(' | '.join(e for r in d['repos'] if r['rel']=='notice-nested' for f in r['findings'] if f['id']=='NOTICE-IN-REPO' for e in f['evidence']))")
[[ "$nested_notice_ev" == *"sub/GEMINI.md:3:"* && "$nested_notice_ev" == *windows-ai-sandbox* ]] \
  && ok "notice-nested: evidence names the nested path and the legacy marker" \
  || bad "notice-nested: evidence wrong (got: $nested_notice_ev)"
[[ "$nested_notice_ev" != *archive* ]] && ok "notice-nested: archive/ excluded" \
  || bad "notice-nested: archive/ reported"

echo "== rule matching (documented semantics)"
python3 - "$WS" <<'EOF' && ok "rule_regex cases" || bad "rule_regex cases"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ws", sys.argv[1]); m = importlib.util.module_from_spec(spec)
sys.modules["ws"] = m   # dataclasses resolve annotations through sys.modules
spec.loader.exec_module(m)
cases = [
    ("python*scripts/x.py*",        "python3 scripts/x.py ARG", True),
    ("python scripts/x.py:*",       "python scripts/x.py ARG",  True),
    ("python scripts/x.py:*",       "python3 scripts/x.py ARG", False),
    ("uv run *scripts/x.py*",       "uv run scripts/x.py ARG",  True),
    ("uv run *scripts/x.py*",       "uv run --locked python3 scripts/x.py ARG", True),
    (".venv*/bin/python*scripts/x.py*", ".venv-sandbox/bin/python3 scripts/x.py ARG", True),
    (".venv*/bin/python*scripts/x.py*", "./.venv/bin/python scripts/x.py ARG", False),
]
bad = [c for c in cases if bool(m.rule_regex(c[0]).match(c[1])) != c[2]]
for c in bad:
    print(f"    mismatch: {c}")
sys.exit(1 if bad else 0)
EOF

echo "== --out guard and --fail-on"
python3 "$WS" --profiles-dir "$PROFILES" --workspaces-root "$ROOT" --also "$HOSTROOT" \
  --out "$ROOT/p1/good/report.md" >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "--out into a tracked path refuses (exit 2)" || bad "--out into a tracked path did not refuse"
[[ ! -e "$ROOT/p1/good/report.md" ]] && ok "--out wrote nothing on refusal" || bad "--out wrote a file despite refusing"
python3 "$WS" --profiles-dir "$PROFILES" --workspaces-root "$ROOT" --also "$HOSTROOT" \
  --out "$ROOT/p1/good/scan.local.md" >/dev/null 2>&1
[[ $? -eq 0 && -f "$ROOT/p1/good/scan.local.md" ]] && ok "--out to an ignored *.local.* path writes" \
  || bad "--out to an ignored path failed"
python3 "$WS" --profiles-dir "$PROFILES" --workspaces-root "$ROOT" --also "$HOSTROOT" \
  --fail-on ASK-GAP >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "--fail-on ASK-GAP exits 1" || bad "--fail-on ASK-GAP did not exit 1"
python3 "$WS" --profiles-dir "$PROFILES" --workspaces-root "$ROOT" --also "$HOSTROOT" \
  --fail-on NO-SUCH-ID >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "--fail-on an absent ID exits 0" || bad "--fail-on an absent ID did not exit 0"
# work/0011's done-check: red while any scanned repo carries a block, green when
# the roots hold none (here: the host-only root alone, profiles dir absent).
python3 "$WS" --profiles-dir "$PROFILES" --workspaces-root "$ROOT" --also "$HOSTROOT" \
  --fail-on NOTICE-IN-REPO >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "--fail-on NOTICE-IN-REPO exits 1" || bad "--fail-on NOTICE-IN-REPO did not exit 1"
python3 "$WS" --profiles-dir "$T/no-profiles" --workspaces-root "$ROOT" --also "$HOSTROOT" \
  --fail-on NOTICE-IN-REPO >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "--fail-on NOTICE-IN-REPO exits 0 with no block in range" \
  || bad "--fail-on NOTICE-IN-REPO exited nonzero with no block in range"

echo
echo "workspace-scan.test: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
