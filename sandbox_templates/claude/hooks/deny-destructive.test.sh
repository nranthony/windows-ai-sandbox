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

# assert <name> <envelope> <expected:pass|deny> [expected_rule_substring]
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

printf "\n  %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
