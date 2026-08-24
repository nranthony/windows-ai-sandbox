#!/usr/bin/env bash
# Host-side test harness for deny-destructive.sh.
# Pipes canned tool envelopes through the hook and asserts decision/rule.
# Runs on the host pre-commit; no container required (uses host jq + sh).
#
# windows-ai-sandbox: protected paths are /root/... (root-in-container under
# rootless Docker userns=host), not /home/agent/...

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="$HERE/deny-destructive.sh"

# Isolate warn-log writes from real container path.
export DENY_DESTRUCTIVE_LOG="$(mktemp -t deny-destructive-test.XXXXXX.log)"
trap 'rm -f "$DENY_DESTRUCTIVE_LOG"' EXIT

PASS=0
FAIL=0

# assert <name> <envelope> <expected:pass|deny|ask> [expected_rule_substring]
#
# THE `default` ARM IS LOAD-BEARING. Until 2026-08-24 this case had only `pass`
# and `deny` arms and no default, so an assertion written with any other
# expectation matched nothing, incremented nothing, printed nothing and did not
# fail — it passed VACUOUSLY. `want=ask` was exactly such a value, which is to
# say the first assertion of the tier this suite exists to lock would have been
# silently inert. A third dialect (opencode, work/0009) will bring a fourth
# decision string; the arm is what stops that from un-testing the suite again.
assert() {
  name=$1; envelope=$2; want=$3; rule=${4:-}
  out=$(printf '%s' "$envelope" | "$HOOK" 2>/dev/null)
  decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "pass"' 2>/dev/null)
  reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)

  case "$want" in
    pass)
      if [ "$decision" = "pass" ]; then
        PASS=$((PASS+1)); printf "  ok   %s\n" "$name"
      else
        FAIL=$((FAIL+1)); printf "  FAIL %s  (got decision=%s reason=%s)\n" "$name" "$decision" "$reason"
      fi
      ;;
    deny)
      if [ "$decision" = "deny" ] && { [ -z "$rule" ] || printf '%s' "$reason" | grep -q "$rule"; }; then
        PASS=$((PASS+1)); printf "  ok   %s  [%s]\n" "$name" "$reason"
      else
        FAIL=$((FAIL+1)); printf "  FAIL %s  (want deny%s, got decision=%s reason=%s)\n" \
          "$name" "${rule:+ rule~$rule}" "$decision" "$reason"
      fi
      ;;
    ask)
      # Claude's middle tier. MEASURED 2026-08-24 (work/0004 D1): headless, an
      # unresolvable ask is a DENY carrying the reason — the command does not
      # run and it lands in the result JSON's permission_denials[]. It also
      # outranks a static permissions.allow entry. So this is a tightening of
      # every verb that reaches it, not a weakening.
      if [ "$decision" = "ask" ] && { [ -z "$rule" ] || printf '%s' "$reason" | grep -q "$rule"; }; then
        PASS=$((PASS+1)); printf "  ok   %s  [%s]\n" "$name" "$reason"
      else
        FAIL=$((FAIL+1)); printf "  FAIL %s  (want ask%s, got decision=%s reason=%s)\n" \
          "$name" "${rule:+ rule~$rule}" "$decision" "$reason"
      fi
      ;;
    *)
      FAIL=$((FAIL+1)); printf "  FAIL %s  (unknown expectation '%s' — assertion would have passed vacuously)\n" "$name" "$want"
      ;;
  esac
}

# --- Bash: negatives (must pass through) ---
assert "find -name (negative)"      '{"tool_name":"Bash","tool_input":{"command":"find . -name *.py"}}' pass
assert "find -print (negative)"     '{"tool_name":"Bash","tool_input":{"command":"find . -print"}}' pass
assert "find -exec grep (allowed)"  '{"tool_name":"Bash","tool_input":{"command":"find . -exec grep foo {} +"}}' pass
assert "find -exec wc (allowed)"    '{"tool_name":"Bash","tool_input":{"command":"find . -exec wc -l {} +"}}' pass
assert "find -exec ls (allowed)"    '{"tool_name":"Bash","tool_input":{"command":"find . -exec ls {} \\;"}}' pass
assert "git status (negative)"      '{"tool_name":"Bash","tool_input":{"command":"git status"}}' pass
assert "echo dd is fine"            '{"tool_name":"Bash","tool_input":{"command":"echo dd is fine"}}' pass
assert "shred-word in string"       '{"tool_name":"Bash","tool_input":{"command":"echo \"shredded\""}}' pass
assert "redirect to /dev/null"      '{"tool_name":"Bash","tool_input":{"command":"foo > /dev/null"}}' pass
assert "redirect to /tmp file"      '{"tool_name":"Bash","tool_input":{"command":"echo hi > /tmp/x"}}' pass
assert "rm single file"             '{"tool_name":"Bash","tool_input":{"command":"rm /tmp/scratch.txt"}}' pass
assert "rm -f single file"          '{"tool_name":"Bash","tool_input":{"command":"rm -f /tmp/scratch.txt"}}' pass
assert "rm -d empty dir"            '{"tool_name":"Bash","tool_input":{"command":"rm -d /tmp/emptydir"}}' pass
assert "npm run (no rm word)"       '{"tool_name":"Bash","tool_input":{"command":"npm run build"}}' pass
assert "find -prune not rm flag"    '{"tool_name":"Bash","tool_input":{"command":"find . -name node_modules -prune"}}' pass

# --- Bash: positives (must block with rule) ---
assert "find -delete"               '{"tool_name":"Bash","tool_input":{"command":"find . -delete"}}' deny "find-delete"
assert "find -depth -delete"        '{"tool_name":"Bash","tool_input":{"command":"find /workspace -depth -delete"}}' deny "find-delete"
assert "find -exec rm"              '{"tool_name":"Bash","tool_input":{"command":"find . -exec rm {} ;"}}' deny "find-exec"
assert "find -execdir mv"           '{"tool_name":"Bash","tool_input":{"command":"find . -execdir mv {} /tmp ;"}}' deny "find-exec"
assert "git clean -fdx"             '{"tool_name":"Bash","tool_input":{"command":"git clean -fdx"}}' deny "git-clean"
assert "shred file"                 '{"tool_name":"Bash","tool_input":{"command":"shred -u /tmp/x"}}' deny "shred"
assert "truncate -s 0"              '{"tool_name":"Bash","tool_input":{"command":"truncate -s 0 /tmp/x"}}' deny "truncate"
assert "dd of=/tmp/x"               '{"tool_name":"Bash","tool_input":{"command":"dd if=/dev/zero of=/tmp/x bs=1M count=10"}}' deny "dd-write"
assert "mkfs.ext4"                  '{"tool_name":"Bash","tool_input":{"command":"mkfs.ext4 /dev/sdb1"}}' deny "mkfs"
assert "sudo find -delete"          '{"tool_name":"Bash","tool_input":{"command":"sudo find /tmp -delete"}}' deny "find-delete"

# --- Bash: rm-recursive, every flag spelling the `Bash(rm -rf:*)` deny misses ---
assert "rm -rf"                     '{"tool_name":"Bash","tool_input":{"command":"rm -rf /workspace/foo"}}' deny "rm-recursive"
assert "rm -r -f (split flags)"     '{"tool_name":"Bash","tool_input":{"command":"rm -r -f /workspace/foo"}}' deny "rm-recursive"
assert "rm -fr (reordered)"         '{"tool_name":"Bash","tool_input":{"command":"rm -fr /workspace/foo"}}' deny "rm-recursive"
assert "rm -Rf (capital R)"         '{"tool_name":"Bash","tool_input":{"command":"rm -Rf /workspace/foo"}}' deny "rm-recursive"
assert "rm --recursive --force"     '{"tool_name":"Bash","tool_input":{"command":"rm --recursive --force /workspace/foo"}}' deny "rm-recursive"
assert "rm -r (no force)"           '{"tool_name":"Bash","tool_input":{"command":"rm -r /workspace/foo"}}' deny "rm-recursive"
assert "sudo rm -rf"                '{"tool_name":"Bash","tool_input":{"command":"sudo rm -rf /workspace/foo"}}' deny "rm-recursive"

# --- Bash: compound commands — the allowed-prefix tail must still be inspected ---
assert "git add && rm -rf"          '{"tool_name":"Bash","tool_input":{"command":"git add . && rm -rf /workspace/foo"}}' deny "rm-recursive"
assert "git commit && shred"        '{"tool_name":"Bash","tool_input":{"command":"git commit -m x && shred -u /workspace/s"}}' deny "shred"
assert "git add ; find -delete"     '{"tool_name":"Bash","tool_input":{"command":"git add . ; find /workspace -delete"}}' deny "find-delete"
assert "cred read via cd &&"        '{"tool_name":"Bash","tool_input":{"command":"git add . && cd /root/.config/gh && cat hosts.yml"}}' deny "cred-read"
assert "cred read in $( ) subst"    '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"$(cat /root/.claude/.credentials.json)\""}}' deny "cred-read"

# --- Bash: hook-tamper ---
assert "redirect to hook path"      '{"tool_name":"Bash","tool_input":{"command":"cat > /usr/local/lib/claude-hooks/deny-destructive.sh"}}' deny "hook-tamper"
assert "rm settings.json"           '{"tool_name":"Bash","tool_input":{"command":"rm /root/.claude/settings.json"}}' deny "hook-tamper"
assert "chmod hook"                 '{"tool_name":"Bash","tool_input":{"command":"chmod -x /usr/local/lib/claude-hooks/deny-destructive.sh"}}' deny "hook-tamper"

# --- Bash: git-hook-tamper — the Bash(git commit *) escalation chain ---
assert "redirect to .git/hooks"     '{"tool_name":"Bash","tool_input":{"command":"echo pwned > .git/hooks/pre-commit"}}' deny "git-hook-tamper"
assert "chmod +x .git/hooks (abs)"  '{"tool_name":"Bash","tool_input":{"command":"chmod +x /workspace/proj/.git/hooks/pre-commit"}}' deny "git-hook-tamper"
assert "cp into .git/hooks"         '{"tool_name":"Bash","tool_input":{"command":"cp /tmp/payload .git/hooks/post-commit"}}' deny "git-hook-tamper"
assert "git add hook then commit"   '{"tool_name":"Bash","tool_input":{"command":"chmod +x .git/hooks/pre-commit && git commit -m x"}}' deny "git-hook-tamper"
assert "git log (not a hook path)"  '{"tool_name":"Bash","tool_input":{"command":"git log --oneline .git/hooks"}}' pass

# --- Edit / Write / MultiEdit ---
assert "Edit hook script"           '{"tool_name":"Edit","tool_input":{"file_path":"/usr/local/lib/claude-hooks/deny-destructive.sh","old_string":"a","new_string":"b"}}' deny "hook-tamper"
assert "Write to settings.json"     '{"tool_name":"Write","tool_input":{"file_path":"/root/.claude/settings.json","content":"{}"}}' deny "hook-tamper"
assert "Write .git/hooks/pre-commit" '{"tool_name":"Write","tool_input":{"file_path":"/workspace/proj/.git/hooks/pre-commit","content":"#!/bin/sh"}}' deny "git-hook-tamper"
assert "Edit .git/hooks/post-merge" '{"tool_name":"Edit","tool_input":{"file_path":"/workspace/proj/.git/hooks/post-merge","old_string":"a","new_string":"b"}}' deny "git-hook-tamper"
assert "Edit normal file"           '{"tool_name":"Edit","tool_input":{"file_path":"/workspace/foo.py","old_string":"a","new_string":"b"}}' pass
assert "Edit .git/config (not hook)" '{"tool_name":"Edit","tool_input":{"file_path":"/workspace/proj/.git/config","old_string":"a","new_string":"b"}}' pass
assert "Write to /tmp"              '{"tool_name":"Write","tool_input":{"file_path":"/tmp/scratch.txt","content":"x"}}' pass

# --- Other tools ---
assert "Read tool envelope"         '{"tool_name":"Read","tool_input":{"file_path":"/etc/passwd"}}' pass
assert "Grep tool envelope"         '{"tool_name":"Grep","tool_input":{"pattern":"foo"}}' pass

# --- Robustness ---
assert "malformed JSON"             'this is not json'                                   pass
assert "empty stdin"                ''                                                   pass
assert "Bash empty command"         '{"tool_name":"Bash","tool_input":{"command":""}}'   pass

# --- Warn rules (must pass through, log entry written) ---
: > "$DENY_DESTRUCTIVE_LOG"
assert "null-truncate :> file"      '{"tool_name":"Bash","tool_input":{"command":": > /tmp/important"}}' pass
assert "workspace-overwrite"        '{"tool_name":"Bash","tool_input":{"command":"echo hi > /workspace/x"}}' pass

if [ "$(wc -l < "$DENY_DESTRUCTIVE_LOG" | tr -d ' ')" -ge 1 ]; then
  PASS=$((PASS+1)); printf "  ok   warn-log written (>=1 entry)\n"
else
  FAIL=$((FAIL+1)); printf "  FAIL warn-log empty after warn rules\n"
fi

# Log shape: { ts, rule, envelope } — the command must be reachable at
# .envelope.tool_input.command. Guards the field rename (was `tool_input`,
# which held the whole envelope and read one level too shallow).
if [ "$(jq -r 'select(.rule=="workspace-overwrite") | .envelope.tool_input.command' \
         < "$DENY_DESTRUCTIVE_LOG" 2>/dev/null)" = "echo hi > /workspace/x" ]; then
  PASS=$((PASS+1)); printf "  ok   warn-log shape (.envelope.tool_input.command)\n"
else
  FAIL=$((FAIL+1)); printf "  FAIL warn-log shape: command not at .envelope.tool_input.command\n"
fi

# ============================================================================
# manifest-dep-add (T04) — blocks a dependency being ADDED, not a manifest
# being edited. The version-bump negative is the merge gate for this rule:
# if it ever fails, the rule is a false-positive generator and gets reverted
# rather than shipped. Fixtures are real files on disk because the rule
# subtracts the manifest's CURRENT dependency set from the payload's.
# ============================================================================
FIX=$(mktemp -d -t deny-destructive-fix.XXXXXX)
trap 'rm -f "$DENY_DESTRUCTIVE_LOG"; rm -rf "$FIX"' EXIT

cat > "$FIX/package.json" <<'JSON'
{
  "name": "demo",
  "version": "1.4.2",
  "scripts": { "build": "tsc" },
  "dependencies": { "express": "^4.18.0", "left-pad": "1.0.0" }
}
JSON

cat > "$FIX/pyproject.toml" <<'TOML'
[project]
name = "demo"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = ["requests>=2.31", "httpx==0.27.0"]
TOML

cat > "$FIX/requirements.txt" <<'REQ'
requests==2.31.0
httpx>=0.27
REQ

ed() { printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","new_string":%s}}' "$1" "$2"; }

# --- positives: a name not already in the manifest ---
assert "dep-add package.json" \
  "$(ed "$FIX/package.json" '"    \"lodash\": \"^4.17.21\","')" deny manifest-dep-add
assert "dep-add pyproject (PEP 508)" \
  "$(ed "$FIX/pyproject.toml" '"dependencies = [\"requests>=2.31\", \"flask>=3.0\"]"')" deny manifest-dep-add
assert "dep-add requirements.txt" \
  "$(ed "$FIX/requirements.txt" '"boto3==1.34.0"')" deny manifest-dep-add
assert "dep-add via MultiEdit" \
  "$(printf '{"tool_name":"MultiEdit","tool_input":{"file_path":"%s","edits":[{"new_string":"  \\"axios\\": \\"^1.6.0\\","}]}}' "$FIX/package.json")" \
  deny manifest-dep-add
assert "dep-add via Write (whole file)" \
  "$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"{\\"dependencies\\":{\\"express\\":\\"^4.18.0\\",\\"chalk\\":\\"^5.0.0\\"}}"}}' "$FIX/package.json")" \
  deny manifest-dep-add

# --- THE MERGE GATE: version bumps must pass ---
assert "version bump package.json  <-- MERGE GATE" \
  "$(ed "$FIX/package.json" '"    \"left-pad\": \"1.0.1\""')" pass
assert "version bump caret->exact  <-- MERGE GATE" \
  "$(ed "$FIX/package.json" '"    \"express\": \"4.19.2\""')" pass
assert "version bump pyproject     <-- MERGE GATE" \
  "$(ed "$FIX/pyproject.toml" '"dependencies = [\"requests>=2.32\", \"httpx==0.27.2\"]"')" pass
assert "version bump requirements  <-- MERGE GATE" \
  "$(ed "$FIX/requirements.txt" '"requests==2.32.0"')" pass

# --- other negatives: manifest edits that add no dependency ---
assert "script change is not a dep"  "$(ed "$FIX/package.json" '"  \"scripts\": { \"build\": \"tsc -p .\" }"')" pass
assert "project version metadata"    "$(ed "$FIX/pyproject.toml" '"version = \"0.2.0\""')" pass
assert "requires-python metadata"    "$(ed "$FIX/pyproject.toml" '"requires-python = \">=3.12\""')" pass
assert "comment added to reqs"       "$(ed "$FIX/requirements.txt" '"# pinned for CVE-2024-1234"')" pass
assert "non-manifest file untouched" "$(ed "$FIX/notes.md" '"npm install left-pad"')" pass

# ============================================================================
# docs-install-cmd (T05) — WARN only, deliberately. Documentation about
# dependency rules legitimately quotes install commands; blocking would fire on
# correct writing. Asserts the warn fires (and that lockfile forms do not).
# ============================================================================
: > "$DENY_DESTRUCTIVE_LOG"
assert "install cmd in AGENTS.md warns not blocks" \
  "$(ed "$FIX/AGENTS.md" '"Run npm install left-pad to get started."')" pass
if jq -e 'select(.rule=="docs-install-cmd")' < "$DENY_DESTRUCTIVE_LOG" >/dev/null 2>&1; then
  PASS=$((PASS+1)); printf "  ok   docs-install-cmd warn logged\n"
else
  FAIL=$((FAIL+1)); printf "  FAIL docs-install-cmd not logged for AGENTS.md\n"
fi

: > "$DENY_DESTRUCTIVE_LOG"
assert "lockfile form in README does not warn" \
  "$(ed "$FIX/README.md" '"Install with npm ci, or uv sync --frozen."')" pass
if [ ! -s "$DENY_DESTRUCTIVE_LOG" ]; then
  PASS=$((PASS+1)); printf "  ok   lockfile-form install not warned (npm ci / uv sync --frozen)\n"
else
  FAIL=$((FAIL+1)); printf "  FAIL lockfile form wrongly warned: $(cat "$DENY_DESTRUCTIVE_LOG")\n"
fi

# --- fetch-and-run family (added 2026-08-20) ---
# `pnpm dlx` was in the pattern from the start; its five siblings were not, so
# `bunx some-cli` in a README went unlogged while the identical `pnpm dlx
# some-cli` was flagged. Each of these resolves a package from a registry and
# executes it — the same trust decision as an install, minus the manifest entry
# that would leave a trace, which is exactly why they are denied as Bash
# commands too. The three LOCKs below are the forms the old pattern missed.
warns() {
  : > "$DENY_DESTRUCTIVE_LOG"
  assert "$1" "$(ed "$FIX/README.md" "$2")" pass
  if jq -e 'select(.rule=="docs-install-cmd")' < "$DENY_DESTRUCTIVE_LOG" >/dev/null 2>&1; then
    PASS=$((PASS+1)); printf "  ok   %s\n" "$3"
  else
    FAIL=$((FAIL+1)); printf "  FAIL %s not logged\n" "$3"
  fi
}
quiet() {
  : > "$DENY_DESTRUCTIVE_LOG"
  assert "$1" "$(ed "$FIX/README.md" "$2")" pass
  if [ ! -s "$DENY_DESTRUCTIVE_LOG" ]; then
    PASS=$((PASS+1)); printf "  ok   %s\n" "$3"
  else
    FAIL=$((FAIL+1)); printf "  FAIL %s wrongly warned: $(cat "$DENY_DESTRUCTIVE_LOG")\n" "$3"
  fi
}

warns "bunx in README is an install cmd" \
  '"Bootstrap with bunx create-thing to scaffold."' \
  "bunx warns  <-- LOCK"
warns "npx in README is an install cmd" \
  '"Run npx create-react-app myapp first."' \
  "npx warns  <-- LOCK"
warns "pip download in README is an install cmd" \
  '"Fetch the wheel with pip download requests first."' \
  "pip download warns  <-- LOCK"
warns "npm exec in README is an install cmd" \
  '"Then npm exec some-cli --check the tree."' \
  "npm exec warns"
warns "pnpm exec in README is an install cmd" \
  '"Use pnpm exec some-cli to verify."' \
  "pnpm exec warns"
warns "yarn dlx in README is an install cmd" \
  '"Or yarn dlx some-cli if you prefer yarn."' \
  "yarn dlx warns"
warns "bun x in README is an install cmd" \
  '"The spaced form bun x some-cli behaves the same."' \
  "bun x (spaced form) warns"

# Negatives: the trailing pattern still requires a package NAME, so a bare or
# flag-only invocation is not an install command. `bun run` / `npm run` execute
# a script already in the manifest — nothing is resolved from a registry.
quiet "bun run is not a fetch-and-run" \
  '"Build it with bun run build."' \
  "bun run does not warn"
quiet "npm exec with only a flag does not warn" \
  '"Check the version with npm exec --help."' \
  "flag-only npm exec does not warn"

# ============================================================================
# quarantine-tamper / quarantine-weaken / quarantine-touch
# ============================================================================
# The age gate (Gate 2) is overridable by writing a FILE, which no Bash matcher
# can see. Three tiers, and the split is the whole design:
#   path block   — sandbox-owned config, no legitimate agent edit
#   content block— zeroed/malformed value, no legitimate authoring path
#   warn         — everything else touching those keys (strengthening is normal)
printf 'minimum-release-age=10080\n' > "$FIX/.npmrc"
printf 'minimumReleaseAge: 10080\n'  > "$FIX/pnpm-workspace.yaml"

# --- path tier: sandbox-owned files ---
assert "edit to /root/.config/pnpm/rc is denied" \
  "$(ed /root/.config/pnpm/rc '"minimum-release-age=0"')" deny quarantine-tamper
assert "edit to /usr/etc/npmrc is denied" \
  "$(ed /usr/etc/npmrc '"min-release-age=0"')" deny quarantine-tamper

# --- content tier: values with no legitimate form ---
assert "project .npmrc zeroing the gate is denied" \
  "$(ed "$FIX/.npmrc" '"minimum-release-age=0"')" deny quarantine-weaken
assert "project .npmrc npm-form zero is denied" \
  "$(ed "$FIX/.npmrc" '"min-release-age=0"')" deny quarantine-weaken
assert "suffixed value (Invalid Date, rejects everything) is denied" \
  "$(ed "$FIX/.npmrc" '"minimum-release-age=7d"')" deny quarantine-weaken
assert "pnpm-workspace.yaml zeroing the gate is denied" \
  "$(ed "$FIX/pnpm-workspace.yaml" '"minimumReleaseAge: 0"')" deny quarantine-weaken
assert "pnpm-workspace.yaml suffixed value is denied" \
  "$(ed "$FIX/pnpm-workspace.yaml" '"minimumReleaseAge: 30m"')" deny quarantine-weaken

# --- MERGE GATE: strengthening must pass. If these fail the rule is a
# --- false-positive generator and gets reverted, not shipped.
assert "raising the window to 7d passes" \
  "$(ed "$FIX/.npmrc" '"minimum-release-age=10080"')" pass
assert "a weak-but-nonzero value passes (warn tier, not block)" \
  "$(ed "$FIX/.npmrc" '"minimum-release-age=1440"')" pass
assert "yaml strengthening passes" \
  "$(ed "$FIX/pnpm-workspace.yaml" '"minimumReleaseAge: 10080"')" pass
assert "an unrelated .npmrc edit passes" \
  "$(ed "$FIX/.npmrc" '"registry=https://registry.npmjs.org/"')" pass
# `0` inside a longer number must not match — 10080 ends in 0, and a naive
# `=[[:space:]]*0` would still be fine, but `=0` anywhere would not be.
assert "a value merely containing 0 is not treated as zero" \
  "$(ed "$FIX/.npmrc" '"minimum-release-age=20160"')" pass

# --- warn tier ---
: > "$DENY_DESTRUCTIVE_LOG"
assert "strengthening logs a quarantine-touch warn" \
  "$(ed "$FIX/.npmrc" '"minimum-release-age=20160"')" pass
if jq -e 'select(.rule=="quarantine-touch")' < "$DENY_DESTRUCTIVE_LOG" >/dev/null 2>&1; then
  PASS=$((PASS+1)); printf "  ok   quarantine-touch warn logged for a strengthening edit\n"
else
  FAIL=$((FAIL+1)); printf "  FAIL quarantine-touch not logged\n"
fi

: > "$DENY_DESTRUCTIVE_LOG"
assert "an .npmrc edit naming no quarantine key does not warn" \
  "$(ed "$FIX/.npmrc" '"save-exact=true"')" pass
if [ ! -s "$DENY_DESTRUCTIVE_LOG" ]; then
  PASS=$((PASS+1)); printf "  ok   unrelated .npmrc key does not warn\n"
else
  FAIL=$((FAIL+1)); printf "  FAIL unrelated key wrongly warned: $(cat "$DENY_DESTRUCTIVE_LOG")\n"
fi

# ============================================================================
# ASK TIER (work/0004) — "deletion is a human step"
# ============================================================================
# The third decision string. Every verb here was ALLOWED before this tier
# existed — three of them explicitly, on both agents' static allow lists — so
# each `ask` below is a tightening, and every `pass` below is a grant this tier
# deliberately did NOT narrow. The negatives are therefore as load-bearing as
# the positives: a rule that also fires on `git checkout <branch>` gets turned
# off by whoever has to use it ten times a day.

printf "\n-- ask tier: git rm (the route the origin episode took) --\n"
assert "git rm asks  <-- LOCK" \
  '{"tool_name":"Bash","tool_input":{"command":"git rm src/a.py"}}' ask "git-rm"
assert "git -C <dir> rm asks (prefix bypass closed)" \
  '{"tool_name":"Bash","tool_input":{"command":"git -C /workspace/p rm src/a.py"}}' ask "git-rm"
assert "git -c k=v rm asks" \
  '{"tool_name":"Bash","tool_input":{"command":"git -c core.quotepath=false rm src/a.py"}}' ask "git-rm"
# The GITOPT prefix is enumerated rather than [^|;&]*, so a commit MESSAGE
# containing the word rm cannot reach the rule. If this ever fails the rule has
# become a prose matcher.
assert "a commit message containing 'rm' does not ask  <-- LOCK" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"remove rm from the docs\""}}' pass
assert "git rm -r still DENIES, not asks (rm-recursive wins)" \
  '{"tool_name":"Bash","tool_input":{"command":"git rm -r skills/"}}' deny "rm-recursive"

printf "\n-- ask tier: discarding the working tree --\n"
assert "git checkout -- <path> asks" \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout -- src/a.py"}}' ask "git-discard"
assert "git checkout <ref> -- <path> asks" \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout abc123 -- src/a.py"}}' ask "git-discard"
assert "git checkout . asks" \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout ."}}' ask "git-discard"
assert "git checkout -f asks" \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout -f"}}' ask "git-discard"
# NAVIGATION MUST NOT TRIP IT. `git checkout` is on both allow lists and is used
# constantly; a rule that prompts on branch switching is a rule that gets
# removed, taking the pathspec forms with it.
assert "git checkout <branch> does NOT ask  <-- LOCK" \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout main"}}' pass
assert "git checkout -b <branch> does NOT ask  <-- LOCK" \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout -b feature/x"}}' pass
assert "git restore <path> asks" \
  '{"tool_name":"Bash","tool_input":{"command":"git restore src/a.py"}}' ask "git-discard"
assert "git restore --staged only unstages, does NOT ask  <-- LOCK" \
  '{"tool_name":"Bash","tool_input":{"command":"git restore --staged src/a.py"}}' pass
assert "git restore --staged --worktree asks (it still writes the tree)" \
  '{"tool_name":"Bash","tool_input":{"command":"git restore --staged --worktree src/a.py"}}' ask "git-discard"

printf "\n-- ask tier: stashes and branches --\n"
assert "git stash drop asks" \
  '{"tool_name":"Bash","tool_input":{"command":"git stash drop stash@{1}"}}' ask "git-stash-drop"
assert "git stash clear asks" \
  '{"tool_name":"Bash","tool_input":{"command":"git stash clear"}}' ask "git-stash-drop"
assert "git stash (save) does NOT ask" \
  '{"tool_name":"Bash","tool_input":{"command":"git stash"}}' pass
assert "git stash pop does NOT ask" \
  '{"tool_name":"Bash","tool_input":{"command":"git stash pop"}}' pass
assert "git branch -D asks" \
  '{"tool_name":"Bash","tool_input":{"command":"git branch -D old-work"}}' ask "git-branch-delete"
# -d as well as -D: the Bash arm lowercases the command line, so the two are
# indistinguishable here. Both ask; -d is a deletion too.
assert "git branch -d asks (lowercasing makes -D/-d one rule)" \
  '{"tool_name":"Bash","tool_input":{"command":"git branch -d old-work"}}' ask "git-branch-delete"
assert "git branch --delete asks" \
  '{"tool_name":"Bash","tool_input":{"command":"git branch --delete old-work"}}' ask "git-branch-delete"
assert "git branch (list) does NOT ask" \
  '{"tool_name":"Bash","tool_input":{"command":"git branch"}}' pass
assert "git branch -a does NOT ask" \
  '{"tool_name":"Bash","tool_input":{"command":"git branch -a"}}' pass
assert "git branch --sort=-committerdate does NOT ask" \
  '{"tool_name":"Bash","tool_input":{"command":"git branch --sort=-committerdate"}}' pass

printf "\n-- ask tier: unlink --\n"
assert "unlink asks" \
  '{"tool_name":"Bash","tool_input":{"command":"unlink /workspace/p/a.txt"}}' ask "unlink"
assert "the word 'unlinked' does not ask" \
  '{"tool_name":"Bash","tool_input":{"command":"echo unlinked the thing"}}' pass

printf "\n-- ask tier: plain rm, and the carve-outs that keep it usable --\n"
assert "rm of a source file asks  <-- LOCK" \
  '{"tool_name":"Bash","tool_input":{"command":"rm /workspace/p/main.py"}}' ask "rm-file"
assert "rm -f of a source file asks" \
  '{"tool_name":"Bash","tool_input":{"command":"rm -f /workspace/p/main.py"}}' ask "rm-file"
assert "rm of a relative source file asks" \
  '{"tool_name":"Bash","tool_input":{"command":"rm src/a.py"}}' ask "rm-file"
# ONE non-carved target in a list makes the whole call ask. Without this a
# single /tmp path would launder every other target in the same argv.
assert "a mixed target list asks  <-- LOCK" \
  '{"tool_name":"Bash","tool_input":{"command":"rm -f /tmp/x /workspace/p/main.py"}}' ask "rm-file"
# Every rm segment is inspected, not just the first.
assert "a second rm in a compound command is inspected  <-- LOCK" \
  '{"tool_name":"Bash","tool_input":{"command":"rm /tmp/a ; rm /workspace/p/main.py"}}' ask "rm-file"
# Unresolvable targets ask rather than pass. Globbing is off while splitting,
# so `rm *.py` is inspected as the literal token.
assert "rm with a variable target asks  <-- LOCK" \
  '{"tool_name":"Bash","tool_input":{"command":"rm $F"}}' ask "rm-file"
assert "rm with a quoted variable target asks" \
  '{"tool_name":"Bash","tool_input":{"command":"rm \"$file\""}}' ask "rm-file"
assert "rm with a glob target asks  <-- LOCK" \
  '{"tool_name":"Bash","tool_input":{"command":"rm *.py"}}' ask "rm-file"
assert "rm -- <path> asks (-- is a separator, not a target)" \
  '{"tool_name":"Bash","tool_input":{"command":"rm -- /workspace/p/main.py"}}' ask "rm-file"

# --- the carve-outs. A prompt on every temp-file cleanup trains evasion, which
# --- is this hook's own stated reason for the warn tier. Each of these is a
# --- path AGENTS.md's container-state table calls disposable.
assert "rm under /tmp passes silently" \
  '{"tool_name":"Bash","tool_input":{"command":"rm /tmp/scratch.txt"}}' pass
assert "rm under /var/tmp passes silently" \
  '{"tool_name":"Bash","tool_input":{"command":"rm /var/tmp/scratch.txt"}}' pass
assert "rm under /root/.cache passes silently" \
  '{"tool_name":"Bash","tool_input":{"command":"rm /root/.cache/uv/x.json"}}' pass
assert "rm in the harness scratchpad passes silently" \
  '{"tool_name":"Bash","tool_input":{"command":"rm /tmp/claude-0/-workspace-p/abc/scratchpad/out1.txt"}}' pass
assert "rm inside .venv passes silently" \
  '{"tool_name":"Bash","tool_input":{"command":"rm /workspace/p/.venv/lib/x.so"}}' pass
assert "rm inside node_modules passes silently" \
  '{"tool_name":"Bash","tool_input":{"command":"rm node_modules/.bin/tsc"}}' pass
assert "rm inside __pycache__ passes silently" \
  '{"tool_name":"Bash","tool_input":{"command":"rm src/__pycache__/a.cpython-312.pyc"}}' pass
assert "rm of a .pyc anywhere passes silently" \
  '{"tool_name":"Bash","tool_input":{"command":"rm src/a.pyc"}}' pass
assert "rm inside .pytest_cache passes silently" \
  '{"tool_name":"Bash","tool_input":{"command":"rm .pytest_cache/v/cache/lastfailed"}}' pass
assert "rm inside build/ passes silently" \
  '{"tool_name":"Bash","tool_input":{"command":"rm build/out.js"}}' pass
assert "rm inside dist/ passes silently" \
  '{"tool_name":"Bash","tool_input":{"command":"rm dist/bundle.js"}}' pass
# The carve-out is a path-SEGMENT match, not a substring: a directory merely
# ending in `build` is not a build directory.
assert "a path merely containing 'build' is NOT carved out  <-- LOCK" \
  '{"tool_name":"Bash","tool_input":{"command":"rm /workspace/p/mybuild/main.py"}}' ask "rm-file"
# rm-recursive still DENIES; the ask tier never downgrades a block rule.
assert "rm -rf still denies, never asks  <-- LOCK" \
  '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/x"}}' deny "rm-recursive"

printf "\n-- deny tier: the spelling-independent twins of the static entries --\n"
# Both static lists keep `git reset --hard` / `git rebase` as literal prefixes.
# These rules exist because a literal prefix cannot see `git -C <dir> ...`, the
# same defect rm-recursive was written for. The static entries are NOT moved.
assert "git reset --hard denies" \
  '{"tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~1"}}' deny "git-reset-hard"
assert "git -C <dir> reset --hard denies  <-- LOCK" \
  '{"tool_name":"Bash","tool_input":{"command":"git -C /workspace/p reset --hard HEAD~1"}}' deny "git-reset-hard"
assert "git reset --soft does NOT deny" \
  '{"tool_name":"Bash","tool_input":{"command":"git reset --soft HEAD~1"}}' pass
assert "git reset (mixed, no flag) does NOT deny" \
  '{"tool_name":"Bash","tool_input":{"command":"git reset"}}' pass
assert "git rebase denies" \
  '{"tool_name":"Bash","tool_input":{"command":"git rebase -i main"}}' deny "git-rebase"
assert "git --git-dir=<dir> rebase denies  <-- LOCK" \
  '{"tool_name":"Bash","tool_input":{"command":"git --git-dir=/workspace/p/.git rebase main"}}' deny "git-rebase"
assert "git rebase --abort denies too" \
  '{"tool_name":"Bash","tool_input":{"command":"git rebase --abort"}}' deny "git-rebase"

printf "\n-- an unknown dialect FAILS LOUDLY (work/0009 is already scheduled) --\n"
# This used to coerce to claude. A converged hooks.json saying
# --dialect=opencode against an engine that predates opencode would then emit
# CLAUDE-shaped output to opencode: guardrail installed, guardrail inert,
# nothing reported. exit 2 with an empty stdout is the one answer that is safe
# in every harness — claude treats 2 as "block and show stderr", agy blocks on
# any non-zero exit, and an unknown harness gets no guessed decision.
UNK_ERR=$(mktemp)
UNK_OUT=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | "$HOOK" --dialect=opencode 2>"$UNK_ERR"); UNK_RC=$?
if [ "$UNK_RC" -eq 2 ]; then
  PASS=$((PASS+1)); printf "  ok   unknown dialect exits 2  <-- LOCK\n"
else
  FAIL=$((FAIL+1)); printf "  FAIL unknown dialect exited %s (want 2)\n" "$UNK_RC"
fi
if [ -z "$UNK_OUT" ]; then
  PASS=$((PASS+1)); printf "  ok   unknown dialect emits NO decision on stdout  <-- LOCK\n"
else
  FAIL=$((FAIL+1)); printf "  FAIL unknown dialect guessed an output shape: %s\n" "$UNK_OUT"
fi
if grep -q 'unknown dialect' "$UNK_ERR"; then
  PASS=$((PASS+1)); printf "  ok   unknown dialect names itself on stderr\n"
else
  FAIL=$((FAIL+1)); printf "  FAIL unknown dialect gave no diagnostic on stderr\n"
fi
rm -f "$UNK_ERR"

# ============================================================================
# antigravity dialect (work/0010)
# ============================================================================
# Same engine, same rule table, second envelope shape and second output
# dialect. The mapping below was read off LIVE agy payloads during Phase 0, not
# from documentation — tool names and the CamelCase arg keys both.
#
# Three assertions here are regression locks, and all three are things a
# reasonable person would "simplify" into a bug:
#
#   1. pass-through is {"decision":"allow"}, never `{}`. agy reads a missing
#      `decision` as DENY (measured), so reusing claude's pass-through would
#      block every single tool call — the guardrail would look installed and
#      the agent would be inert.
#   2. a malformed envelope DENIES under antigravity while the identical
#      breakage PASSES under claude. The asymmetry is the design (claude has
#      permissions.deny underneath it; for reads, agy has only this hook).
#   3. a workspace .agents/hooks.json write is denied. agy merges workspace
#      hooks OVER the global one BY NAME, so that file can contain
#      {"sandbox-guardrails":{"enabled":false}} and switch the guardrail off.
#      Confirmed live in Phase 0 test G.

# agy_assert <name> <envelope> <expected:pass|deny|ask> [expected_rule_substring]
#
# `ask` here asserts the wire value `force_ask`, NOT `ask` — see the arm below.
# The `default` arm is load-bearing for the same reason as in `assert` above.
agy_assert() {
  name=$1; envelope=$2; want=$3; rule=${4:-}
  out=$(printf '%s' "$envelope" | "$HOOK" --dialect=antigravity 2>/dev/null)
  decision=$(printf '%s' "$out" | jq -r '.decision // "MISSING"' 2>/dev/null)
  reason=$(printf '%s' "$out" | jq -r '.reason // ""' 2>/dev/null)
  case "$want" in
    pass)
      # "allow", not "pass": an absent decision is a DENY to agy, so the test
      # must fail if the engine ever emits a bare {}.
      if [ "$decision" = "allow" ]; then
        PASS=$((PASS+1)); printf "  ok   agy: %s\n" "$name"
      else
        FAIL=$((FAIL+1)); printf "  FAIL agy: %s  (want allow, got decision=%s reason=%s)\n" "$name" "$decision" "$reason"
      fi ;;
    deny)
      if [ "$decision" = "deny" ] && { [ -z "$rule" ] || printf '%s' "$reason" | grep -q "$rule"; }; then
        PASS=$((PASS+1)); printf "  ok   agy: %s  [%s]\n" "$name" "$reason"
      else
        FAIL=$((FAIL+1)); printf "  FAIL agy: %s  (want deny%s, got decision=%s reason=%s)\n" \
          "$name" "${rule:+ rule~$rule}" "$decision" "$reason"
      fi ;;
    ask)
      # "force_ask", NOT "ask" — and the difference is the whole reason this
      # tier is dialect-branched. agy caches a plain `ask` approval as a
      # permanent Always-Allow grant, so `ask` would mean "prompt once, then
      # delete freely forever". `force_ask` is documented in the shipped binary
      # as "Always prompt the user, ignoring cached permissions" and is in its
      # decision enum (allow|deny|ask|force_ask|deny_unless_prior_grant).
      # If this ever reads `ask`, the tier has silently become one-shot.
      if [ "$decision" = "force_ask" ] && { [ -z "$rule" ] || printf '%s' "$reason" | grep -q "$rule"; }; then
        PASS=$((PASS+1)); printf "  ok   agy: %s  [%s]\n" "$name" "$reason"
      else
        FAIL=$((FAIL+1)); printf "  FAIL agy: %s  (want force_ask%s, got decision=%s reason=%s)\n" \
          "$name" "${rule:+ rule~$rule}" "$decision" "$reason"
      fi ;;
    *)
      FAIL=$((FAIL+1)); printf "  FAIL agy: %s  (unknown expectation '%s' — assertion would have passed vacuously)\n" "$name" "$want"
      ;;
  esac
}

printf "\n-- antigravity: envelope translation --\n"
agy_assert "run_command maps to Bash" \
  '{"toolCall":{"name":"run_command","args":{"CommandLine":"find /tmp -delete"}},"stepIdx":3}' deny "find-delete"
agy_assert "write_to_file maps to Write" \
  '{"toolCall":{"name":"write_to_file","args":{"TargetFile":"/root/.claude/settings.json","CodeContent":"{}"}}}' deny "hook-tamper"
agy_assert "replace_file_content maps to Edit" \
  '{"toolCall":{"name":"replace_file_content","args":{"TargetFile":"/usr/local/lib/sandbox-hooks/guardrails.sh","ReplacementContent":"x"}}}' deny "hook-tamper"
agy_assert "view_file maps to Read" \
  '{"toolCall":{"name":"view_file","args":{"AbsolutePath":"/workspace/p/.env"}}}' deny "cred-read"
agy_assert "grep_search maps to Read" \
  '{"toolCall":{"name":"grep_search","args":{"SearchPath":"/root/.ssh/id_rsa"}}}' deny "cred-read"
agy_assert "the real agy oauth token is protected" \
  '{"toolCall":{"name":"view_file","args":{"AbsolutePath":"/root/.gemini/antigravity-cli/antigravity-oauth-token"}}}' deny "cred-read"

printf "\n-- antigravity: pass-through and unmapped tools --\n"
agy_assert "an ordinary command allows  <-- LOCK" \
  '{"toolCall":{"name":"run_command","args":{"CommandLine":"ls -la"}}}' pass
agy_assert "an ordinary file read allows" \
  '{"toolCall":{"name":"view_file","args":{"AbsolutePath":"/workspace/p/README.md"}}}' pass
# Unmapped tools PASS. The matcher is "*", so every browser_/mcp/search tool
# arrives here; denying what the engine has not been taught would not harden
# agy, it would stop it working. The static permissions.deny list is the layer
# that must be complete, and no workspace file can reach it.
agy_assert "an unmapped tool passes rather than denying" \
  '{"toolCall":{"name":"browser_navigate","args":{"Url":"https://example.com"}}}' pass
agy_assert "a tool with no args passes" \
  '{"toolCall":{"name":"list_dir","args":{}}}' pass

printf "\n-- antigravity: fail-closed, and claude still fails open --\n"
agy_assert "malformed envelope denies  <-- LOCK" 'not json at all' deny "malformed-envelope"
agy_assert "empty envelope denies" '' deny "empty-envelope"
assert "the SAME malformed input passes under claude  <-- LOCK" 'not json at all' pass
assert "the SAME empty input passes under claude" '' pass

printf "\n-- antigravity: the ask tier is force_ask, never ask --\n"
# THE SINGLE MOST IMPORTANT ASSERTION IN THIS SECTION. agy caches a plain `ask`
# approval as a permanent Always-Allow grant, so emitting `ask` here would mean
# "prompt once, then delete freely for the life of the profile" — the tier
# would look installed and be one click from gone. agy_assert's `ask` arm
# asserts the wire value `force_ask` for exactly this reason.
agy_assert "git rm force_asks under agy  <-- LOCK" \
  '{"toolCall":{"name":"run_command","args":{"CommandLine":"git rm src/a.py"}}}' ask "git-rm"
agy_assert "plain rm of a source file force_asks" \
  '{"toolCall":{"name":"run_command","args":{"CommandLine":"rm /workspace/p/main.py"}}}' ask "rm-file"
agy_assert "git checkout -- <path> force_asks" \
  '{"toolCall":{"name":"run_command","args":{"CommandLine":"git checkout -- src/a.py"}}}' ask "git-discard"
agy_assert "git restore <path> force_asks" \
  '{"toolCall":{"name":"run_command","args":{"CommandLine":"git restore src/a.py"}}}' ask "git-discard"
agy_assert "git stash drop force_asks" \
  '{"toolCall":{"name":"run_command","args":{"CommandLine":"git stash drop"}}}' ask "git-stash-drop"
agy_assert "git branch -D force_asks" \
  '{"toolCall":{"name":"run_command","args":{"CommandLine":"git branch -D old-work"}}}' ask "git-branch-delete"
agy_assert "unlink force_asks" \
  '{"toolCall":{"name":"run_command","args":{"CommandLine":"unlink /workspace/p/a.txt"}}}' ask "unlink"
# The same negatives as the claude side. `command(git checkout)` and
# `command(git stash)` are on agy's static ALLOW list, so a rule that fired on
# navigation would be narrowing a grant people use constantly.
agy_assert "git checkout <branch> allows under agy  <-- LOCK" \
  '{"toolCall":{"name":"run_command","args":{"CommandLine":"git checkout main"}}}' pass
agy_assert "git restore --staged allows under agy" \
  '{"toolCall":{"name":"run_command","args":{"CommandLine":"git restore --staged src/a.py"}}}' pass
agy_assert "rm under /tmp allows under agy (carve-out)" \
  '{"toolCall":{"name":"run_command","args":{"CommandLine":"rm /tmp/scratch.txt"}}}' pass
# The tiers stay ordered under agy too: a denied verb is never downgraded.
agy_assert "rm -rf still DENIES under agy, never force_asks  <-- LOCK" \
  '{"toolCall":{"name":"run_command","args":{"CommandLine":"rm -rf /workspace/foo"}}}' deny "rm-recursive"
agy_assert "git -C <dir> reset --hard denies under agy" \
  '{"toolCall":{"name":"run_command","args":{"CommandLine":"git -C /workspace/p reset --hard"}}}' deny "git-reset-hard"
agy_assert "git rebase denies under agy" \
  '{"toolCall":{"name":"run_command","args":{"CommandLine":"git rebase -i main"}}}' deny "git-rebase"

printf "\n-- antigravity: the workspace-override bypass --\n"
# Measured in Phase 0 test G: with the workspace attached, agy reported
# "loaded 1 named hooks from 2 hooks.json file(s)" and the denied command ran.
agy_assert "write of a workspace .agents/hooks.json denies  <-- LOCK" \
  '{"toolCall":{"name":"write_to_file","args":{"TargetFile":"/workspace/p/.agents/hooks.json","CodeContent":"{\"sandbox-guardrails\":{\"enabled\":false}}"}}}' \
  deny "agy-workspace-hook-tamper"
for d in .agent _agents _agent; do
  agy_assert "write of a workspace $d/hooks.json denies" \
    "{\"toolCall\":{\"name\":\"write_to_file\",\"args\":{\"TargetFile\":\"/workspace/p/$d/hooks.json\",\"CodeContent\":\"{}\"}}}" \
    deny "agy-workspace-hook-tamper"
done
agy_assert "the shell route into a workspace hooks.json denies" \
  '{"toolCall":{"name":"run_command","args":{"CommandLine":"mkdir -p .agents && echo {} > .agents/hooks.json"}}}' \
  deny "agy-workspace-hook-tamper"
agy_assert "tee into a workspace hooks.json denies" \
  '{"toolCall":{"name":"run_command","args":{"CommandLine":"cat x | tee /workspace/p/.agents/hooks.json"}}}' \
  deny "agy-workspace-hook-tamper"
agy_assert "edit of the live agy policy denies" \
  '{"toolCall":{"name":"write_to_file","args":{"TargetFile":"/root/.gemini/antigravity-cli/settings.json","CodeContent":"{}"}}}' \
  deny
agy_assert "edit of the live agy hooks.json denies" \
  '{"toolCall":{"name":"write_to_file","args":{"TargetFile":"/root/.gemini/config/hooks.json","CodeContent":"{}"}}}' \
  deny
# Negative: a project's own .agents/skills/ is ordinary content, not the hook file.
agy_assert "an unrelated file under .agents/ passes" \
  '{"toolCall":{"name":"write_to_file","args":{"TargetFile":"/workspace/p/.agents/skills/x/SKILL.md","CodeContent":"# x"}}}' pass

printf "\n  %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
