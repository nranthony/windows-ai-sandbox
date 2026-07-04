#!/bin/sh
# deny-destructive: PreToolUse hook. Inspects the full tool envelope on stdin
# and either passes through ('{}') or blocks via the Claude Code hook output
# contract (https://code.claude.com/docs/en/hooks.md):
#
#   {"hookSpecificOutput":{
#      "hookEventName":"PreToolUse",
#      "permissionDecision":"deny",
#      "permissionDecisionReason":"deny-destructive: <rule>: <msg>"}}
#
# Closes the deny-list bypass class where the prefix matcher in
# permissions.deny cannot see destructive flags (find -delete, dd of=, etc.)
# or path targets (Edit to /usr/local/lib/claude-hooks/...). See
# docs/deny-destructive-hook-plan.md.
#
# Fail-open on script error: a broken hook must not brick the agent. The
# verify-sandbox.sh tripwire and the audit settings probe catch a
# permanently-broken hook within one cycle.
#
# windows-ai-sandbox note: container runs as root (UID 0) under rootless
# Docker userns=host. Protected paths are /root/... here, not /home/agent/...
# The kernel write-protect that macolima relies on (root-owned 0755 file,
# agent UID 1000) does NOT apply here — the agent IS root. The Edit and Bash
# tamper rules below are the *only* enforcement layer for the hook script
# itself; this is defence-in-depth on top of permissions.deny, not a hard
# kernel boundary. Image rebuild restores the canonical hook on every up.

set -u
trap 'printf "{}\n"; exit 0' EXIT INT HUP TERM

LOG="${DENY_DESTRUCTIVE_LOG:-/root/.cache/deny-destructive.log}"

emit_pass() { printf '{}\n'; trap - EXIT; exit 0; }

emit_block() {
  rule=$1; msg=$2
  reason="deny-destructive: ${rule}: ${msg}"
  # jq builds the envelope so reason strings with quotes/newlines stay safe.
  # `-c` keeps output compact (single line) — easier for downstream greps and
  # marginally lighter for the harness to parse.
  printf '%s' "$reason" \
    | jq -Rsc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:.}}'
  trap - EXIT
  exit 0
}

warn_log() {
  rule=$1; payload=$2
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || ts="?"
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  # JSON-line: { ts, rule, tool_input } — full envelope kept for warn->block review.
  printf '%s' "$payload" \
    | jq -c --arg ts "$ts" --arg rule "$rule" \
        '{ts:$ts, rule:$rule, tool_input:.}' >> "$LOG" 2>/dev/null || true
}

# ---------- read envelope ----------
envelope=$(cat)
[ -z "$envelope" ] && emit_pass

tool_name=$(printf '%s' "$envelope" | jq -r '.tool_name // empty' 2>/dev/null) || emit_pass
[ -z "$tool_name" ] && emit_pass

# ---------- Edit / Write / MultiEdit ----------
case "$tool_name" in
  Edit|Write|MultiEdit)
    fp=$(printf '%s' "$envelope" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    [ -z "$fp" ] && emit_pass
    # realpath -m: canonicalise without requiring existence.
    rp=$(realpath -m "$fp" 2>/dev/null) || rp="$fp"
    case "$rp" in
      /usr/local/lib/claude-hooks/*)
        emit_block "hook-tamper" "edit to in-image hook script is denied; ask the user to rebuild" ;;
      /root/.claude/settings.json)
        emit_block "hook-tamper" "edit to live settings.json is denied; ask the user to run this" ;;
      /etc/claude/*)
        emit_block "hook-tamper" "edit under /etc/claude/ is denied; ask the user to run this" ;;
    esac
    emit_pass
    ;;
esac

# ---------- Bash ----------
[ "$tool_name" = "Bash" ] || emit_pass

cmd=$(printf '%s' "$envelope" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$cmd" ] && emit_pass

# Normalise: lowercase, strip leading sudo/time/nice/ionice (and any flags up
# to the next token). Lowercase is fine — Linux paths are case-sensitive, so
# a casing mismatch wouldn't hit the protected location anyway.
norm=$(printf '%s' "$cmd" | tr 'A-Z' 'a-z')
# Strip leading wrappers iteratively.
while :; do
  case "$norm" in
    'sudo '*|'time '*|'nice '*|'ionice '*)
      norm=$(printf '%s' "$norm" | sed -E 's/^(sudo|time|nice|ionice)[[:space:]]+//') ;;
    *) break ;;
  esac
done

match() { printf '%s' "$norm" | grep -Eq "$1"; }

# Order matters: first hit wins.

# 1. find-delete — the bypass that motivated the hook.
if match '\bfind\b[^|;&]*[[:space:]]-delete\b'; then
  emit_block "find-delete" "find -delete is destructive; ask the user to run this"
fi

# 2. find-exec — NARROW. Only block when the executed token is a destructive
#    command. Allows benign find . -exec grep|wc|file|ls.
if match '\bfind\b[^|;&]*[[:space:]]-(exec|execdir|ok)[[:space:]]+(rm|mv|dd|truncate|shred|tee|chmod|chown)\b'; then
  emit_block "find-exec" "find -exec invoking a destructive command; ask the user to run this"
fi

# 3. git-clean — `-fdx` wipe.
if match '\bgit[[:space:]]+clean\b'; then
  emit_block "git-clean" "git clean wipes untracked files; ask the user to run this"
fi

# 4. shred
if match '\bshred\b'; then
  emit_block "shred" "shred destructively overwrites; ask the user to run this"
fi

# 5. truncate
if match '\btruncate\b'; then
  emit_block "truncate" "truncate destructively resizes; ask the user to run this"
fi

# 6. dd-write
if match '\bdd\b[^|;&]*[[:space:]]of='; then
  emit_block "dd-write" "dd of= is a raw block write; ask the user to run this"
fi

# 7. mkfs
if match '\bmkfs(\.[a-z0-9]+)?\b'; then
  emit_block "mkfs" "mkfs creates a filesystem; ask the user to run this"
fi

# 8. hook-tamper (Bash side) — defence in depth on the kernel write-protect.
if match '(>|>>|\btee\b|\bchmod\b|\bchown\b|\bmv\b|\bcp\b|\brm\b|\bln\b)[^|;&]*(/usr/local/lib/claude-hooks/|/root/\.claude/settings\.json|/etc/claude/)'; then
  emit_block "hook-tamper" "write/modify of hook or settings file is denied; ask the user to rebuild"
fi

# 9. cred-read — block ANY Bash command that references the agent's credential
#    stores. The agent runs as root here (rootless userns), so claude-settings'
#    Read-tool denies and the kernel write-protect do NOT cover `cat`/`cp`/`rg`/
#    `tar`/`ln` against these paths. Matching the path substring against the
#    whole command catches read, copy, archive, and symlink-creation alike,
#    regardless of the leading verb. Covers /root/... and the ~ / $HOME forms.
#    Residual gaps (cd-then-bare-filename, scripts run via allowed interpreters)
#    are documented in docs/permissions-model.md — this is defence-in-depth.
if match '(/root/|~/|\$\{?home\}?/)(\.gemini\b|\.config/(gh|glab-cli)\b|\.claude/\.credentials|\.claude\.json|\.aws\b|\.ssh\b)'; then
  emit_block "cred-read" "access to credential/identity store is denied; ask the user to run this"
fi
# 9b. cred-read by bare filename — catches `cd /root/.config/gh && cat …` style
#     references where the directory was changed first. These filenames are
#     credential-specific enough to block unconditionally.
if match '(oauth_creds\.json|google_accounts\.json|\.credentials\.json)'; then
  emit_block "cred-read" "access to a credential file is denied; ask the user to run this"
fi

# 10. null-truncate (WARN) — `: > file` and bare `> file` clobber.
#    Excludes /dev/null, /dev/stderr, fd-redirects (>&), heredocs, and the
#    common `cmd > /tmp/x` redirection that overwrites a file the agent owns.
#    We only flag truly bare-leading clobbers at command start or after ; or &&.
#    Promote to block after one clean week of warn-log review.
if match '(^|[;&]|\|\|)[[:space:]]*:?[[:space:]]*>[[:space:]]*[^&[:space:]/]' \
   && ! match '>[[:space:]]*/dev/(null|stderr|stdout)\b'; then
  warn_log "null-truncate" "$envelope"
fi

# 11. workspace-overwrite (WARN) — bare clobber into /workspace.
if match '>[[:space:]]*/workspace/[^[:space:]]'; then
  warn_log "workspace-overwrite" "$envelope"
fi

emit_pass
