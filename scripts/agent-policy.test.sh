#!/usr/bin/env bash
# agent-policy.test.sh — the policy suite for EVERY code agent.
#
# Offline: no docker, no network, no `agy`, no `claude`. Reads the templates and
# runs the REAL convergence functions out of scripts/profile.sh.
#
# Was `antigravity-parity.test.sh` until 2026-08-24 (work/0011). It grew a
# second job — the convergence that now serves both agents — so it is named for
# what it covers rather than for the agent that arrived first. Adding opencode
# means a descriptor row and a section here, not a third suite.
#
# TWO JOBS
# --------
#
# 1. PARITY. The sandbox carries two static tool-policy lists that say the same
#    thing in two grammars:
#
#      sandbox_templates/claude/claude-settings.json            Bash(npm install:*)
#      sandbox_templates/antigravity/antigravity-settings.json  command(npm install)
#
#    Both matchers are PREFIX matchers over the command line, so the mapping is
#    one-to-one and mechanical. Two lists that must agree and are edited by hand
#    will drift — that is not a prediction, it is what happened to `pnpm dlx`
#    and its five fetch-and-run siblings, which sat in one list and not the
#    other for months (commit ebf7392). The check is exact in both directions
#    with deliberately NO exception list, because an exception list is where
#    drift goes to hide.
#
# 2. CONVERGENCE. Every agent's policy is reconciled to its template on every
#    `up` (work/0011, ADR-0007) by ONE function with a per-agent mode. The modes
#    are OPPOSITE and that asymmetry is the thing most likely to be "cleaned up"
#    into a hole: claude OVERWRITES (it has repo-local files to hold its
#    preferences), `agy` MERGES (it has none, and what it stores in that file is
#    functional state). Unifying them either destroys live `agy` state or lets a
#    stale Claude key survive enforcement.
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
#   * convergence is file-scoped, never the ADR-0005 directory mirror;
#   * the agy merge preserves agy's own keys, and the claude overwrite CAPTURES
#     what it drops — including a change INSIDE an owned key, which is the case
#     that actually happened (an in-session `ask`->`allow` promotion landing in
#     `permissions`, reverted with no record).

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
# BOTH templates are STRICT JSON annotated with '_'-prefixed keys; neither uses
# // comments. That is what lets ONE merge implementation serve both agents with
# no JSONC parser anywhere. This suite used to strip // comments from the claude
# template and carried a comment claiming the two files differed in comment
# style — measured, they do not, and the stripper was dead code hiding the fact
# that a stray // would have been silently tolerated here and rejected by
# Claude Code. Parse both the same way, strictly.
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CLAUDE_TPL" \
  && ok "claude-settings.json parses as STRICT json (no // comments)" \
  || bad "claude-settings.json does not parse"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$AGY_TPL" \
  && ok "antigravity-settings.json parses as STRICT json (no // comments)" \
  || bad "antigravity-settings.json does not parse — agy will ignore the whole policy"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$AGY_HOOKS" \
  && ok "hooks.json parses" || bad "hooks.json does not parse"

printf "\n-- deny parity --\n"
python3 - "$CLAUDE_TPL" "$AGY_TPL" <<'PY'
import json, re, sys

claude = json.load(open(sys.argv[1]))["permissions"]
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

# allow and ask are diffed as strictly as deny, and the 2026-08-24 myclickup
# promotion is exactly why: moving three writes from `ask` to `allow` in one
# file and not the other would leave the two agents with different postures on
# a real ClickUp workspace, silently.
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

# ---------------------------------------------------------------------------
# CONVERGENCE
# ---------------------------------------------------------------------------
# These run the REAL functions out of scripts/profile.sh, not a copy, so the
# thing under test is the thing `up` executes.
CTMP=$(mktemp -d) || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$CTMP"' EXIT

policy_src() {
  sed -n '/^AGENT_POLICY_DESCRIPTORS=(/,/^)$/p'          scripts/profile.sh
  sed -n '/^converge_agent_policy()/,/^}$/p'             scripts/profile.sh
  sed -n '/^converge_antigravity_hooks()/,/^}$/p'        scripts/profile.sh
  sed -n '/^converge_agent_policies()/,/^}$/p'           scripts/profile.sh
}

# run_converge <profiles_root> <profile> [flags...] -> stdout+stderr of the
# real converge. Flags are passed straight through to converge_agent_policies,
# which is how `--defaults` is exercised here exactly as the CLI passes it.
run_converge() {
  local root="$1" prof="$2"; shift 2
  bash -c "
set -u
SCRIPT_DIR='$PWD'
PROFILES_ROOT='$root'
PROFILE='$prof'
warn(){ echo \"warn: \$*\"; }
info(){ echo \"info: \$*\"; }
ok(){ :; }
$(policy_src)
converge_agent_policies \"\$@\"
" _ "$@" 2>&1
}

printf "\n-- the descriptor table keeps the two modes OPPOSITE --\n"
# The asymmetry is principled, not accidental: overwrite where the agent has
# somewhere else to put its preferences, merge where it does not. Collapsing it
# in either direction is a real failure — merge-for-claude silently preserves a
# key a future release makes security-relevant, overwrite-for-agy destroys
# trustedWorkspaces on every `up` with nowhere to restore it from.
modes=$(sed -n '/^AGENT_POLICY_DESCRIPTORS=(/,/^)$/p' scripts/profile.sh \
        | grep -o '|overwrite|\||merge|' | tr -d '|' | tr '\n' ' ')
[[ "$modes" == "overwrite merge " ]] \
  && ok "descriptors: claude OVERWRITEs, antigravity MERGEs  <-- LOCK" \
  || bad "descriptor modes changed (got: '$modes') — the two modes must stay opposite"

printf "\n-- antigravity: convergence merges, never mirrors --\n"
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
# both.
mkdir -p "$CTMP/p/gemini-home/config/projects" "$CTMP/p/gemini-home/antigravity-cli" "$CTMP/p/claude-home"
printf '{"userSettings":{"remoteControlHostname":"x"}}\n' > "$CTMP/p/gemini-home/config/config.json"
: > "$CTMP/p/gemini-home/config/mcp_config.json"
: > "$CTMP/p/gemini-home/config/.migrated"
printf '{"colorScheme":"tokyo night","model":"m","enableTelemetry":false,"trustedWorkspaces":["/workspace/x"]}\n' \
  > "$CTMP/p/gemini-home/antigravity-cli/settings.json"
# The claude half of the same profile, carrying exactly what the live profiles
# carry (work/0011 F6) plus the two cases the capture exists for.
python3 - "$CTMP/p/claude-home/settings.json" "$CLAUDE_TPL" <<'PY2'
import json, sys
tpl = json.load(open(sys.argv[2]))
live = json.loads(json.dumps(tpl))
live["model"] = "claude-fable-5[1m]"
live["effortLevel"] = "high"
live["agentPushNotifEnabled"] = True
live["skipAutoPermissionPrompt"] = True     # user-or-managed scope: must SURVIVE
# An in-session "Yes, and don't ask again" landing in a sandbox-OWNED key.
live["permissions"]["allow"] = list(live["permissions"]["allow"]) + ["Bash(rm -rf:*)"]
json.dump(live, open(sys.argv[1], "w"), indent=2)
PY2
# A file the sandbox never seeded, beside the policy: file-scoped means it lives.
printf 'not ours\n' > "$CTMP/p/claude-home/CLAUDE.md"

CONV1=$(run_converge "$CTMP" p) || bad "converge_agent_policies errored"

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
missing = [k for k in ("colorScheme", "model", "enableTelemetry", "trustedWorkspaces")
           if k not in d]
if missing:
    print("  FAIL converge OVERWROTE agy's own settings, lost: %s" % ", ".join(missing))
    sys.exit(1)
print("  ok   converge preserved every agy runtime key (F4 set)  <-- LOCK")
if not (d.get("permissions", {}).get("deny")) or d.get("toolPermission") != "request-review":
    print("  FAIL converge did not write both owned keys (permissions, toolPermission)")
    sys.exit(1)
print("  ok   converge wrote both agy owned keys (%d deny rules)" % len(d["permissions"]["deny"]))
PY2
if [[ $? -eq 0 ]]; then PASS=$((PASS+2)); else FAIL=$((FAIL+1)); fi

printf "\n-- claude: convergence overwrites, and the loss is CAPTURED --\n"
DISC="$CTMP/p/claude-home/settings.discarded.json"
python3 - "$CTMP/p/claude-home/settings.json" "$CLAUDE_TPL" "$DISC" <<'PY2'
import json, sys
live = json.load(open(sys.argv[1]))
tpl  = json.load(open(sys.argv[2]))
fails = 0
def check(cond, msg):
    global fails
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        fails += 1

check(live["permissions"] == tpl["permissions"],
      "claude overwrite REVERTED the in-session grant in `permissions`  <-- LOCK")
# PRESERVE, half one: a LIVE value survives. All three preference keys were set
# to something other than the template default before this converge ran; every
# one of them must come back unchanged, or the operator re-picks model and
# effort after every `up`. Until 2026-08-24 this asserted the opposite — that
# the three were DROPPED — which is the behaviour the owner decision reversed.
check(live.get("model") == "claude-fable-5[1m]"
      and live.get("effortLevel") == "high"
      and live.get("agentPushNotifEnabled") is True,
      "the preserve list kept the live model/effortLevel/agentPushNotifEnabled "
      "(they differ from the template defaults, which is the point)  <-- LOCK")
check(live.get("skipAutoPermissionPrompt") is True,
      "the preserve list kept `skipAutoPermissionPrompt` (user-or-managed scope: nowhere else to live)  <-- LOCK")

d = json.load(open(sys.argv[3]))
check(d["dropped"] == {},
      "a preserved key is NOT a dropped key — nothing is captured for the four of them")
check("permissions" in d["owned_key_changes"],
      "the OWNED-key content diff is captured too — a top-level capture alone "
      "misses an ask->allow promotion  <-- LOCK")
check("Bash(rm -rf:*)" in json.dumps(d["owned_key_changes"]["permissions"]["was_live"]),
      "the captured owned-key diff carries what was actually there")
sys.exit(1 if fails else 0)
PY2
if [[ $? -eq 0 ]]; then PASS=$((PASS+6)); else FAIL=$((FAIL+1)); fi

[[ -f "$CTMP/p/claude-home/CLAUDE.md" ]] \
  && ok "convergence is file-scoped in claude-home too (an unseeded sibling survives)  <-- LOCK" \
  || bad "convergence deleted an unseeded file in claude-home — it must never mirror a directory"

case "$CONV1" in
  *"DISCARDED"*"$DISC"*|*"$DISC"*) ok "the warning names the discard FILE, not a blob to copy out of scrollback" ;;
  *) bad "the converge warning does not name $DISC (got: $CONV1)" ;;
esac

printf "\n-- idempotent, and the warning is not furniture --\n"
before_agy=$(cat "$CTMP/p/gemini-home/antigravity-cli/settings.json")
before_cla=$(cat "$CTMP/p/claude-home/settings.json")
CONV2=$(run_converge "$CTMP" p)
[[ "$before_agy" == "$(cat "$CTMP/p/gemini-home/antigravity-cli/settings.json")" ]] \
  && ok "agy merge is idempotent" || bad "agy merge rewrites the file on every run"
[[ "$before_cla" == "$(cat "$CTMP/p/claude-home/settings.json")" ]] \
  && ok "claude overwrite is idempotent" || bad "claude overwrite rewrites the file on every run"
# WARN-ON-CHANGE. Claude rewrites model and effortLevel every session, so an
# unconditional warning fires on every `up` forever and stops being read —
# going quiet in the reader's head exactly when a genuinely new key appears.
case "$CONV2" in
  *DISCARDED*|*REVERTED*) bad "the converge warning fired again with nothing changed — that is how a warning becomes furniture" ;;
  *) ok "a second converge with an unchanged dropped set is SILENT  <-- LOCK" ;;
esac
# The capture is the last ACTUAL discard, not the last run. The run right after
# a converge drops nothing (the live file IS the template until the agent next
# writes to it), so blanking on an empty run would give the operator exactly one
# `up` to notice a captured grant before the record of it disappeared.
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["owned_key_changes"] else 1)' "$DISC" \
  && ok "a clean converge does not BLANK the previous capture  <-- LOCK" \
  || bad "a converge with nothing to drop erased the previous recovery capture"

# ... but a NEW key must break the silence.
python3 - "$CTMP/p/claude-home/settings.json" <<'PY2'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["someKeyAFutureReleaseInvents"] = 1
json.dump(d, open(p, "w"), indent=2)
PY2
CONV3=$(run_converge "$CTMP" p)
case "$CONV3" in
  *someKeyAFutureReleaseInvents*) ok "a NEW dropped key breaks the silence  <-- LOCK" ;;
  *) bad "a newly-appeared top-level key was dropped SILENTLY (got: $CONV3)" ;;
esac

printf "\n-- preserve, half two: the template DEFAULT seeds a profile that lacks the key --\n"
# The state every profile was left in by the pre-flip converge: a live policy
# that IS the template, with the three preference keys dropped out of it. That
# is not "the operator chose nothing", it is "the operator's choice was thrown
# away", and a preserve list alone leaves it that way forever. The defaults in
# the template are the half that fixes it.
mkdir -p "$CTMP/stripped/claude-home"
python3 - "$CTMP/stripped/claude-home/settings.json" "$CLAUDE_TPL" <<'PY2'
import json, sys
tpl = json.load(open(sys.argv[2]))
live = {k: v for k, v in tpl.items()
        if k not in ("model", "effortLevel", "agentPushNotifEnabled")}
json.dump(live, open(sys.argv[1], "w"), indent=2)
PY2
run_converge "$CTMP" stripped >/dev/null 2>&1
python3 - "$CTMP/stripped/claude-home/settings.json" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1]))
want = {"model": "opus", "effortLevel": "medium", "agentPushNotifEnabled": False}
got = {k: d.get(k) for k in want}
if got != want:
    print("  FAIL converge did not seed the template preference defaults (got %r)" % got)
    sys.exit(1)
print("  ok   a live policy MISSING the preference keys is seeded opus/medium/false  <-- LOCK")
PY2
if [[ $? -eq 0 ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi

printf "\n-- converge --defaults resets the preferences, and CAPTURES what it replaced --\n"
# The opt-out. Everything above says a live preference wins; this says the
# operator can still get back to the template on demand. It is an explicit
# action, so unlike the drop/revert warnings it is never silenced by a matching
# previous signature — and it is captured, because a reset the operator cannot
# undo is the same silent loss the capture exists to prevent.
before_defaults=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("model"))' \
                  "$CTMP/p/claude-home/settings.json")
[[ "$before_defaults" == "claude-fable-5[1m]" ]] \
  && ok "precondition: the live model is still the operator's, not the template's" \
  || bad "precondition failed — live model is '$before_defaults'"
CONV4=$(run_converge "$CTMP" p --defaults)
python3 - "$CTMP/p/claude-home/settings.json" "$DISC" <<'PY2'
import json, sys
live = json.load(open(sys.argv[1]))
d    = json.load(open(sys.argv[2]))
fails = 0
def check(cond, msg):
    global fails
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        fails += 1

check(live.get("model") == "opus" and live.get("effortLevel") == "medium"
      and live.get("agentPushNotifEnabled") is False,
      "--defaults overwrote the live preferences with the template defaults  <-- LOCK")
r = d.get("preference_resets", {})
check(r.get("model", {}).get("was_live") == "claude-fable-5[1m]",
      "the replaced value is CAPTURED, not merely overwritten  <-- LOCK")
check(sorted(r) == ["agentPushNotifEnabled", "effortLevel", "model"],
      "every reset preference is captured")
sys.exit(1 if fails else 0)
PY2
if [[ $? -eq 0 ]]; then PASS=$((PASS+3)); else FAIL=$((FAIL+1)); fi
case "$CONV4" in
  *RESET*model*) ok "--defaults SAYS what it reset" ;;
  *) bad "--defaults reset a preference silently (got: $CONV4)" ;;
esac
# skipAutoPermissionPrompt is on the preserve list and has NO template default.
# `--defaults` has nothing to reset it to, and dropping it would be a one-way
# loss of a key a repo file cannot hold — so it survives even here.
python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("skipAutoPermissionPrompt") is True else 1)' \
  "$CTMP/p/claude-home/settings.json" \
  && ok "--defaults leaves a preserved key with no template default ALONE  <-- LOCK" \
  || bad "--defaults dropped skipAutoPermissionPrompt, which no repo file can hold"
# And an ordinary converge afterwards must not undo the reset.
run_converge "$CTMP" p >/dev/null 2>&1
python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["model"] == "opus" else 1)' \
  "$CTMP/p/claude-home/settings.json" \
  && ok "the next ordinary converge preserves the RESET value, not the old one" \
  || bad "an ordinary converge resurrected the pre-reset preference"

printf "\n-- a corrupt live policy is the agent's to report, not ours to replace --\n"
mkdir -p "$CTMP/corrupt/claude-home" "$CTMP/corrupt/gemini-home/antigravity-cli"
printf '{ this is not json\n' > "$CTMP/corrupt/claude-home/settings.json"
printf '{ neither is this\n'   > "$CTMP/corrupt/gemini-home/antigravity-cli/settings.json"
run_converge "$CTMP" corrupt >/dev/null 2>&1
grep -q 'this is not json' "$CTMP/corrupt/claude-home/settings.json" \
  && ok "a corrupt claude policy is left alone (its other keys may still be recoverable by hand)" \
  || bad "converge overwrote a corrupt claude policy — the hand-recoverable content is gone"
grep -q 'neither is this' "$CTMP/corrupt/gemini-home/antigravity-cli/settings.json" \
  && ok "a corrupt agy policy is left alone" \
  || bad "converge overwrote a corrupt agy policy"

printf "\n-- bootstraps a profile where no agent has ever run --\n"
mkdir -p "$CTMP/fresh"
run_converge "$CTMP" fresh >/dev/null 2>&1
fresh_ok=1
for f in gemini-home/config/hooks.json gemini-home/antigravity-cli/settings.json claude-home/settings.json; do
  [[ -s "$CTMP/fresh/$f" ]] || fresh_ok=0
done
[[ "$fresh_ok" == 1 ]] \
  && ok "converge bootstraps every agent policy on a profile with no state" \
  || bad "converge failed to bootstrap a fresh profile"
[[ -f "$CTMP/fresh/claude-home/settings.discarded.json" ]] \
  && bad "converge wrote a discard capture on a profile with nothing to discard" \
  || ok "no discard capture is written when nothing was dropped"
# A bootstrap has no live value for anything, so every preserved key falls
# through to the template default. The exact values are asserted, not just their
# presence: they are an owner decision (2026-08-24), and "opus" is deliberately
# the unsuffixed id.
python3 - "$CTMP/fresh/claude-home/settings.json" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1]))
want = {"model": "opus", "effortLevel": "medium", "agentPushNotifEnabled": False}
got = {k: d.get(k) for k in want}
if got != want:
    print("  FAIL a bootstrapped profile did not get the template preference defaults (got %r)" % got)
    sys.exit(1)
print("  ok   a bootstrapped profile gets model=opus, effortLevel=medium, push notifs off  <-- LOCK")
PY2
if [[ $? -eq 0 ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi

printf "\n  %d passed, %d failed\n\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
