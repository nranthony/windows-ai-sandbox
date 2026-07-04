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

# --- Bash: hook-tamper ---
assert "redirect to hook path"      '{"tool_name":"Bash","tool_input":{"command":"cat > /usr/local/lib/claude-hooks/deny-destructive.sh"}}' deny "hook-tamper"
assert "rm settings.json"           '{"tool_name":"Bash","tool_input":{"command":"rm /root/.claude/settings.json"}}' deny "hook-tamper"
assert "chmod hook"                 '{"tool_name":"Bash","tool_input":{"command":"chmod -x /usr/local/lib/claude-hooks/deny-destructive.sh"}}' deny "hook-tamper"

# --- Edit / Write / MultiEdit ---
assert "Edit hook script"           '{"tool_name":"Edit","tool_input":{"file_path":"/usr/local/lib/claude-hooks/deny-destructive.sh","old_string":"a","new_string":"b"}}' deny "hook-tamper"
assert "Write to settings.json"     '{"tool_name":"Write","tool_input":{"file_path":"/root/.claude/settings.json","content":"{}"}}' deny "hook-tamper"
assert "Edit normal file"           '{"tool_name":"Edit","tool_input":{"file_path":"/workspace/foo.py","old_string":"a","new_string":"b"}}' pass
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

printf "\n  %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
