#!/usr/bin/env bash
# antigravity-parity.test.sh — the two agents must deny the same set.
#
# Offline: no docker, no network, no `agy`. Reads two template files.
#
# WHY THIS SUITE EXISTS
# ---------------------
# The sandbox now carries two static tool-policy lists that say the same thing
# in two grammars:
#
#   sandbox_templates/claude/claude-settings.json       Bash(npm install:*)
#   sandbox_templates/antigravity/antigravity-settings.json  command(npm install)
#
# Both matchers are PREFIX matchers over the command line, so the mapping is
# one-to-one and mechanical. Two lists that must agree and are edited by hand
# will drift — that is not a prediction, it is what happened to `pnpm dlx` and
# its five fetch-and-run siblings, which sat in one list and not the other for
# months (commit ebf7392).
#
# So the parity check is the control: add a command to BOTH files or to
# neither. The check is exact in both directions — there is deliberately no
# exception list, because an exception list is where drift goes to hide. If the
# two lists must ever genuinely differ, that is a design change worth an ADR
# amendment, not a line in a skip array.
#
# Assertions marked <-- LOCK below are the ones proven to bite:
#   * deny parity in BOTH directions — a missing deny is the hole, and an
#     unexplained extra means someone edited one file and not the other;
#   * `Read(...)` denials have NO command() equivalent, so the antigravity deny
#     list must stay command()-only: a reader who "completes" the conversion by
#     inventing read(...)/file(...) grants gets strings agy stores and never
#     matches, and would believe reads are gated when they are not;
#   * the hooks.json command path agrees with the Dockerfile symlink target — a
#     mismatch means the hook never runs and NOTHING reports it, because a
#     hooks.json naming a missing script just logs and carries on unguarded;
#   * the two failure postures stay DIFFERENT (claude open, antigravity closed);
#   * the antigravity pass-through is an explicit allow, never `{}`;
#   * convergence merges and is file-scoped, never the ADR-0005 mirror.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf "  ok   %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$1"; }

CLAUDE_TPL=sandbox_templates/claude/claude-settings.json
AGY_TPL=sandbox_templates/antigravity/antigravity-settings.json
AGY_HOOKS=sandbox_templates/antigravity/hooks.json
HOOK_SRC=sandbox_templates/claude/hooks/deny-destructive.sh

for f in "$CLAUDE_TPL" "$AGY_TPL" "$AGY_HOOKS" "$HOOK_SRC"; do
  [[ -f "$f" ]] || { printf "missing: %s\n" "$f"; exit 1; }
done

printf "\n-- templates parse --\n"
# claude-settings.json carries // comments; agy's carries "_comment" keys
# instead, because agy decodes it with a Go JSON decoder and we verified it
# tolerates unknown keys but not comments.
python3 - "$CLAUDE_TPL" <<'PY' && ok "claude-settings.json parses (after comment strip)" || bad "claude-settings.json does not parse"
import json, re, sys
json.loads(re.sub(r'^\s*//.*$', '', open(sys.argv[1]).read(), flags=re.M))
PY
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$AGY_TPL" \
  && ok "antigravity-settings.json parses as STRICT json (no // comments)" \
  || bad "antigravity-settings.json does not parse — agy will ignore the whole policy"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$AGY_HOOKS" \
  && ok "hooks.json parses" || bad "hooks.json does not parse"

printf "\n-- deny parity --\n"
python3 - "$CLAUDE_TPL" "$AGY_TPL" <<'PY'
import json, re, sys

claude = json.loads(re.sub(r'^\s*//.*$', '', open(sys.argv[1]).read(), flags=re.M))["permissions"]
agy    = json.load(open(sys.argv[2]))["permissions"]

def bash_entries(lst):
    """Bash(x:*) and Bash(x) -> x. Everything else (Read(...), bare tool names
    like `Glob`) is not a command grant and is returned separately."""
    cmds, other = set(), set()
    for e in lst:
        m = re.fullmatch(r'Bash\((.*?)(?::\*)?\)', e)
        (cmds if m else other).add(m.group(1) if m else e)
    return cmds, other

def agy_cmds(lst):
    out = set()
    for e in lst:
        m = re.fullmatch(r'command\((.*)\)', e)
        if m:
            out.add(m.group(1))
    return out

fails = []
def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        fails.append(msg)

for key in ("deny", "allow", "ask"):
    c_cmd, c_other = bash_entries(claude.get(key, []))
    a_cmd = agy_cmds(agy.get(key, []))
    missing = sorted(c_cmd - a_cmd)
    extra   = sorted(a_cmd - c_cmd)
    lock = "  <-- LOCK" if key == "deny" else ""
    check(not missing, "every claude %s command has an antigravity twin%s%s"
          % (key, lock, ("" if not missing else " | missing: " + ", ".join(missing))))
    check(not extra, "antigravity %s adds nothing claude lacks%s"
          % (key, ("" if not extra else " | extra: " + ", ".join(extra))))

# Read(...) denials cannot be expressed as command() grants. If someone
# "finishes the job" by inventing read(...)/file(...) forms, agy stores the
# string and never matches it — reads would look gated and not be.
c_reads = [e for e in claude.get("deny", []) if e.startswith("Read(")]
a_nonc  = [e for e in agy.get("deny", []) if not re.fullmatch(r'command\(.*\)', e)]
check(bool(c_reads), "claude denies secret reads via Read(...) (sanity)")
check(not a_nonc, "antigravity deny list is command() ONLY  <-- LOCK%s"
      % ("" if not a_nonc else " | non-command grants: " + ", ".join(a_nonc)))

check(agy.get("deny") and len(agy["deny"]) >= 80,
      "antigravity deny list is not truncated (%d rules)" % len(agy.get("deny", [])))

sys.exit(1 if fails else 0)
PY
if [[ $? -eq 0 ]]; then PASS=$((PASS+9)); else FAIL=$((FAIL+1)); fi

printf "\n-- the hook is actually wired --\n"
# A hooks.json naming a script that does not exist is not an error to agy: it
# logs and carries on unguarded. So the path in the template, the symlink the
# Dockerfile creates, and the dialect flag the script parses must agree.
HOOK_CMD=$(python3 -c '
import json;print(json.load(open("sandbox_templates/antigravity/hooks.json"))["sandbox-guardrails"]["PreToolUse"][0]["hooks"][0]["command"])')
HOOK_PATH=${HOOK_CMD%% *}
grep -q "$HOOK_PATH" Dockerfile \
  && ok "hooks.json command path is created by the Dockerfile  <-- LOCK ($HOOK_PATH)" \
  || bad "hooks.json names $HOOK_PATH but the Dockerfile never creates it — the hook would silently never run"
case "$HOOK_CMD" in
  *--dialect=antigravity*) ok "hooks.json passes --dialect=antigravity" ;;
  *) bad "hooks.json does not pass --dialect=antigravity — the hook would emit claude's '{}', which agy reads as DENY on every call" ;;
esac
grep -q 'DIALECT=${_arg#--dialect=}' "$HOOK_SRC" \
  && ok "the engine parses --dialect=" || bad "the engine no longer parses --dialect="
python3 -c '
import json,sys
h=json.load(open("sandbox_templates/antigravity/hooks.json"))["sandbox-guardrails"]
sys.exit(0 if h.get("enabled") is True and h["PreToolUse"][0]["matcher"]=="*" else 1)' \
  && ok 'hooks.json is enabled and matches "*" (not an enumerated tool list)' \
  || bad 'hooks.json is disabled, or the matcher enumerates tools — a renamed upstream tool would stop matching silently'

printf "\n-- failure posture is not unified --\n"
# The single most likely "cleanup" is to make both dialects behave the same
# here. They must not: claude fails open on top of its own deny list,
# antigravity fails closed because it IS the read-path control and because agy
# reads `{}` as deny anyway.
out=$(printf 'not json' | sh "$HOOK_SRC" --dialect=antigravity 2>/dev/null)
[[ "$out" == *'"decision":"deny"'* ]] \
  && ok "malformed envelope DENIES under antigravity  <-- LOCK" \
  || bad "malformed envelope did not deny under antigravity (got: $out)"
out=$(printf 'not json' | sh "$HOOK_SRC" 2>/dev/null)
[[ "$out" == "{}" ]] \
  && ok "malformed envelope PASSES under claude (fail-open, deliberate)  <-- LOCK" \
  || bad "claude fail-open posture changed (got: $out)"
out=$(printf '%s' '{"toolCall":{"name":"run_command","args":{"CommandLine":"ls -la"}}}' | sh "$HOOK_SRC" --dialect=antigravity 2>/dev/null)
[[ "$out" == *'"decision":"allow"'* ]] \
  && ok "antigravity pass-through is an explicit allow, never {}  <-- LOCK" \
  || bad "antigravity pass-through is not an explicit allow (got: $out) — agy reads a missing decision as DENY"

printf "\n-- convergence merges, never mirrors --\n"
# THREE regression locks, all of them data-loss shaped.
#
# converge_skills MIRRORS (ADR-0005): a file absent from the template is
# deleted from the profile. That is right for skills and catastrophic here,
# because gemini-home/config/ is shared with agy — config.json, mcp_config.json,
# .migrated and projects/ live there and no template will ever contain them.
# And antigravity-cli/settings.json is shared with the RUNNING agent: agy writes
# colorScheme, model and trustedWorkspaces into the same file we write
# permissions into.
#
# Anyone generalising the skills converge to "also do antigravity" reintroduces
# both. These run the real function out of profile.sh, not a copy.
CTMP=$(mktemp -d) || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$CTMP"' EXIT
mkdir -p "$CTMP/p/gemini-home/config/projects" "$CTMP/p/gemini-home/antigravity-cli"
printf '{"userSettings":{"remoteControlHostname":"x"}}\n' > "$CTMP/p/gemini-home/config/config.json"
: > "$CTMP/p/gemini-home/config/mcp_config.json"
: > "$CTMP/p/gemini-home/config/.migrated"
printf '{"colorScheme":"tokyo night","model":"m","trustedWorkspaces":["/workspace/x"]}\n' \
  > "$CTMP/p/gemini-home/antigravity-cli/settings.json"

bash -c "
set -eu
SCRIPT_DIR='$PWD'
PROFILES_ROOT='$CTMP'
PROFILE=p
warn(){ echo \"warn: \$*\" >&2; }
$(sed -n '/^converge_antigravity()/,/^}/p' scripts/profile.sh)
converge_antigravity
" >/dev/null 2>&1 || bad "converge_antigravity errored"

for f in config.json mcp_config.json .migrated projects; do
  [[ -e "$CTMP/p/gemini-home/config/$f" ]] \
    && ok "converge left live agy state alone: config/$f  <-- LOCK" \
    || bad "converge DELETED config/$f — this is a directory mirror, it must be file-scoped"
done
[[ -s "$CTMP/p/gemini-home/config/hooks.json" ]] \
  && ok "converge wrote hooks.json" || bad "converge did not write hooks.json"

python3 - "$CTMP/p/gemini-home/antigravity-cli/settings.json" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1]))
missing = [k for k in ("colorScheme", "model", "trustedWorkspaces") if k not in d]
if missing:
    print("  FAIL converge OVERWROTE agy's own settings, lost: %s" % ", ".join(missing))
    sys.exit(1)
print("  ok   converge preserved agy's own settings keys  <-- LOCK")
if not (d.get("permissions", {}).get("deny")):
    print("  FAIL converge did not write permissions.deny")
    sys.exit(1)
print("  ok   converge wrote permissions.deny (%d rules)" % len(d["permissions"]["deny"]))
PY2
if [[ $? -eq 0 ]]; then PASS=$((PASS+2)); else FAIL=$((FAIL+1)); fi

# Idempotence: a second run must not churn the file (converge runs on EVERY up).
before=$(cat "$CTMP/p/gemini-home/antigravity-cli/settings.json")
bash -c "
set -eu
SCRIPT_DIR='$PWD'
PROFILES_ROOT='$CTMP'
PROFILE=p
warn(){ :; }
$(sed -n '/^converge_antigravity()/,/^}/p' scripts/profile.sh)
converge_antigravity
" >/dev/null 2>&1
[[ "$before" == "$(cat "$CTMP/p/gemini-home/antigravity-cli/settings.json")" ]] \
  && ok "converge is idempotent" || bad "converge rewrites the file on every run"

# A profile that has never run agy: converge must create, not crash.
mkdir -p "$CTMP/fresh"
bash -c "
set -eu
SCRIPT_DIR='$PWD'
PROFILES_ROOT='$CTMP'
PROFILE=fresh
warn(){ echo \"warn: \$*\" >&2; }
$(sed -n '/^converge_antigravity()/,/^}/p' scripts/profile.sh)
converge_antigravity
" >/dev/null 2>&1 \
  && [[ -s "$CTMP/fresh/gemini-home/config/hooks.json" ]] \
  && [[ -s "$CTMP/fresh/gemini-home/antigravity-cli/settings.json" ]] \
  && ok "converge bootstraps a profile that has never run agy" \
  || bad "converge failed on a fresh profile"

printf "\n  %d passed, %d failed\n\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
