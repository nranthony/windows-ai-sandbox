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

# Extract dependency NAMES from a manifest blob. Handles the four shapes that
# actually appear: package.json `"pkg": "^1.0"`, poetry `pkg = "^1.0"`,
# PEP 508 list entries `"pkg>=1.0"`, and bare requirements.txt `pkg==1.0`.
# Metadata keys that look like dependencies (`version = "0.1.0"`,
# `requires-python = ">=3.11"`) are filtered out by name — they would otherwise
# be reported as new dependencies when a manifest is created from scratch.
# Output is sorted+unique so `comm` can diff two sets directly.
dep_names() {
  # Split on JSON/TOML structural characters first. Without this the match is
  # line-oriented and misses every compact manifest — `{"a":"^1","b":"^2"}` and
  # `dependencies = ["x>=1", "y>=2"]` both put several dependencies on one line,
  # and a missed OLD name is the dangerous direction: it makes an existing
  # dependency look newly added and fires on a version bump.
  printf '%s\n' "$1" | tr '{}[],' '\n' | sed -n '
    s/^[[:space:]]*"\([A-Za-z0-9@._/-]\{1,\}\)"[[:space:]]*:[[:space:]]*"[~^><=0-9*].*$/\1/p
    s/^[[:space:]]*\([A-Za-z0-9._-]\{1,\}\)[[:space:]]*=[[:space:]]*"[~^><=0-9*].*$/\1/p
    s/^[[:space:]]*"\{0,1\}\([A-Za-z0-9._-]\{1,\}\)[><=~!].*$/\1/p
  ' | grep -Fxv -e version -e name -e description -e readme -e license \
        -e authors -e keywords -e classifiers -e requires-python -e python \
        -e homepage -e repository -e documentation -e changelog \
    | sort -u
}

warn_log() {
  rule=$1; payload=$2
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || ts="?"
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  # JSON-line: { ts, rule, envelope } — the WHOLE tool envelope is kept for the
  # warn->block review, so the command lives at .envelope.tool_input.command.
  # (Field was named `tool_input` before, which read as if it held just the
  # inner object and sent log greps one level too shallow.)
  printf '%s' "$payload" \
    | jq -c --arg ts "$ts" --arg rule "$rule" \
        '{ts:$ts, rule:$rule, envelope:.}' >> "$LOG" 2>/dev/null || true
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
      */.git/hooks/*)
        # git runs these on commit/merge/checkout. With Bash(git commit *) on an
        # allow list, writing one here turns the next commit into unprompted
        # arbitrary execution — the tail end of the chain is pre-approved, so
        # this write is the only place left to stop it.
        emit_block "git-hook-tamper" "write to a .git/hooks/ script is denied; git executes these on commit — ask the user to install it" ;;
      /root/.config/pnpm/rc|/root/.npmrc|/usr/etc/npmrc)
        # Sandbox-owned quarantine config, not project config: /root/.config/pnpm/rc
        # is written by profile.sh ensure_state on every `up`, and /usr/etc/npmrc is
        # baked into the image. These hold the age gate (Gate 2) that stops a
        # freshly-published slopsquat from resolving. An agent edit here is tamper
        # with no legitimate form — a project that needs different settings uses its
        # own .npmrc, which is handled by the content rule below. Matched on full
        # path because the pnpm file's basename is the bare word `rc`.
        emit_block "quarantine-tamper" "edit to the sandbox's own package-manager config ($rp) is denied; it holds the resolution age gate. A per-project setting belongs in that project's .npmrc; a change to the sandbox default is the user's to make." ;;
    esac

    # Payload actually being written: Edit(new_string) / Write(content) /
    # MultiEdit(edits[].new_string), concatenated.
    payload=$(printf '%s' "$envelope" | jq -r '
      [ .tool_input.new_string?, .tool_input.content?,
        (.tool_input.edits? // [])[].new_string? ]
      | map(select(.)) | join("\n")' 2>/dev/null) || payload=""

    case "$(basename "$rp")" in
      # ---------- manifest dependency additions ----------
      # An install command is not the only way to add a dependency: editing a
      # manifest and then running an ALLOWED build command (`uv run`,
      # `pnpm run build`, `make`) resolves it just the same. No Bash matcher can
      # see that, so it is caught here.
      #
      # Blocks a dependency being ADDED, not a manifest being edited. The set of
      # dependency names already in the file on disk is subtracted from the set
      # in the payload; only genuinely new names block. That is what lets a
      # version bump, a script change, or a metadata edit through — the name is
      # already present, so nothing is added. Comparing against the file rather
      # than against old_string matters: an Edit payload is only a fragment.
      package.json|pyproject.toml|Pipfile|requirements*.txt)
        if [ -n "$payload" ]; then
          old_blob=""
          [ -f "$rp" ] && old_blob=$(cat "$rp" 2>/dev/null)
          _o=$(mktemp 2>/dev/null) || _o=""
          _n=$(mktemp 2>/dev/null) || _n=""
          if [ -n "$_o" ] && [ -n "$_n" ]; then
            dep_names "$old_blob"  > "$_o" 2>/dev/null
            dep_names "$payload"   > "$_n" 2>/dev/null
            added=$(comm -13 "$_o" "$_n" 2>/dev/null | head -5 | tr '\n' ' ')
            rm -f "$_o" "$_n"
            if [ -n "$added" ]; then
              emit_block "manifest-dep-add" \
"new dependency in $(basename "$rp"): ${added}- adding a dependency is a trust-boundary change, not an implementation detail. Stop and tell the user the package name, what it is for, and why an existing dependency will not do. Verify it exists on the registry first: a 404 means the name was invented, and a 'similar' name is not a substitute. Version bumps and metadata edits are not affected by this rule."
            fi
          fi
        fi
        ;;
      # ---------- install commands in instruction files ----------
      # These files are executable surfaces: an install command written here is
      # run by the next agent and pasted by the next human. WARN, not block —
      # documentation about dependency rules legitimately quotes install
      # commands (this repo's own agent-notice.md does), so blocking would fire
      # on correct writing. Reviewed from the warn log before any promotion to
      # block. Bare/lockfile forms (`npm ci`, `uv sync --frozen`) are ignored:
      # the trailing pattern requires a non-flag argument, i.e. a package name.
      AGENTS.md|CLAUDE.md|GEMINI.md|SKILL.md|README.md|CONTRIBUTING.md|agent-notice.md|.cursorrules|*.mdc)
        if printf '%s' "$payload" | grep -Eq '(npm[[:space:]]+(i|install|add)|pnpm[[:space:]]+(add|install|dlx)|yarn[[:space:]]+add|bun[[:space:]]+add|pip3?[[:space:]]+install|uv[[:space:]]+add|uv[[:space:]]+pip[[:space:]]+install|pipx[[:space:]]+install|poetry[[:space:]]+add|cargo[[:space:]]+(install|add)|go[[:space:]]+(install|get))[[:space:]]+[^-[:space:]]' 2>/dev/null; then
          warn_log "docs-install-cmd" "$envelope"
        fi
        ;;
      # ---------- project-level quarantine overrides ----------
      # A PROJECT .npmrc or pnpm-workspace.yaml is legitimate config, so this is
      # not a path block. But config precedence is cli > env > project > user >
      # global, which means one of these files switches the age gate off for its
      # directory — no install command, nothing for a Bash matcher to see.
      #
      # Two tiers, split on whether a legitimate authoring path exists:
      #
      #   BLOCK — zeroed or malformed. Nobody has a reason to write
      #     `minimum-release-age=0`, and a suffixed value is worse than off (pnpm
      #     computes value*60*1e3 -> NaN -> Invalid Date -> every version
      #     rejected, which fails closed and reads as a broken registry). Both are
      #     targeted enough for rule-13 treatment.
      #
      #   WARN — any other touch of these keys. STRENGTHENING is legitimate and
      #     common (this repo's own plans tell people to commit 10080), and a
      #     registry pin is ordinary config; blocking those would fire on correct
      #     work and train evasion. Note a shell redirect bypasses this arm
      #     entirely, which is the other reason not to over-block here: the warn
      #     log is the promotion path, not a wall.
      .npmrc|pnpm-workspace.yaml|npmrc)
        if [ -n "$payload" ] && printf '%s' "$payload" | grep -Eq \
             '^[[:space:]]*(min-release-age|minimum-release-age)[[:space:]]*=[[:space:]]*(0([^0-9]|$)|[0-9]+[A-Za-z])|^[[:space:]]*minimumReleaseAge[[:space:]]*:[[:space:]]*(0([^0-9]|$)|[0-9]+[A-Za-z])' 2>/dev/null; then
          emit_block "quarantine-weaken" \
"this write switches OFF or breaks the resolution age gate in $(basename "$rp"). The gate is what stops a package published (or hijacked) minutes ago from resolving — it is the main defence against slopsquatting, and project config overrides the sandbox-wide setting. A value of 0 disables it; a suffixed value (e.g. 7d) makes pnpm compute an Invalid Date and reject EVERY version, which looks like a broken registry. If a specific install genuinely needs a newer package, that is the user's call to make explicitly."
        elif [ -n "$payload" ] && printf '%s' "$payload" | grep -Eq \
             '(min-release-age|minimum-release-age|minimumReleaseAge)|^[[:space:]]*registry[[:space:]]*=' 2>/dev/null; then
          warn_log "quarantine-touch" "$envelope"
        fi
        ;;
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

# 3. rm-recursive — spelling-independent. permissions.deny carries
#    `Bash(rm -rf:*)`, but that is a literal prefix: `rm -r -f`, `rm -fr`,
#    `rm -Rf`, and `rm --recursive --force` all walk straight past it. Match on
#    "a short-flag cluster containing r, or --recursive" instead of one spelling.
#    The cluster is restricted to rm's own short flags ([dfirv]) so a stray
#    `-print`/`-prune` elsewhere in the segment can't trigger it. Non-recursive
#    `rm file` and `rm -f file` still pass — this targets tree deletion only.
#    Note `git rm -r --cached` trips this too; that is a deliberate false
#    positive (deny is fail-safe, and `git rm` is not on the allow list anyway).
if match '\brm\b[^|;&]*[[:space:]]-([dfirv]*r[dfirv]*|-recursive)\b'; then
  emit_block "rm-recursive" "recursive rm is destructive; ask the user to run this"
fi

# 4. git-clean — `-fdx` wipe.
if match '\bgit[[:space:]]+clean\b'; then
  emit_block "git-clean" "git clean wipes untracked files; ask the user to run this"
fi

# 5. shred
if match '\bshred\b'; then
  emit_block "shred" "shred destructively overwrites; ask the user to run this"
fi

# 6. truncate
if match '\btruncate\b'; then
  emit_block "truncate" "truncate destructively resizes; ask the user to run this"
fi

# 7. dd-write
if match '\bdd\b[^|;&]*[[:space:]]of='; then
  emit_block "dd-write" "dd of= is a raw block write; ask the user to run this"
fi

# 8. mkfs
if match '\bmkfs(\.[a-z0-9]+)?\b'; then
  emit_block "mkfs" "mkfs creates a filesystem; ask the user to run this"
fi

# 9. hook-tamper (Bash side) — defence in depth on the kernel write-protect.
if match '(>|>>|\btee\b|\bchmod\b|\bchown\b|\bmv\b|\bcp\b|\brm\b|\bln\b)[^|;&]*(/usr/local/lib/claude-hooks/|/root/\.claude/settings\.json|/etc/claude/)'; then
  emit_block "hook-tamper" "write/modify of hook or settings file is denied; ask the user to rebuild"
fi

# 9b. git-hook-tamper (Bash side) — mirror of the Edit/Write case above, for the
#     redirect/cp/chmod route into a repo's .git/hooks/. The `chmod` verb is the
#     load-bearing one: a hook script git will not run is inert until it is made
#     executable, and `chmod` is neither on the allow list nor a read-only
#     command. Unanchored `\.git/hooks/` so relative paths count too.
if match '(>|>>|\btee\b|\bchmod\b|\bchown\b|\bmv\b|\bcp\b|\bln\b|\binstall\b)[^|;&]*\.git/hooks/'; then
  emit_block "git-hook-tamper" "write/chmod of a .git/hooks/ script is denied; git executes these on commit — ask the user to install it"
fi

# 10. cred-read — block ANY Bash command that references the agent's credential
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
# 10b. cred-read by bare filename — catches `cd /root/.config/gh && cat …` style
#     references where the directory was changed first. These filenames are
#     credential-specific enough to block unconditionally.
if match '(oauth_creds\.json|google_accounts\.json|\.credentials\.json)'; then
  emit_block "cred-read" "access to a credential file is denied; ask the user to run this"
fi

# 11. null-truncate (WARN) — `: > file` and bare `> file` clobber.
#    Excludes /dev/null, /dev/stderr, fd-redirects (>&), heredocs, and the
#    common `cmd > /tmp/x` redirection that overwrites a file the agent owns.
#    We only flag truly bare-leading clobbers at command start or after ; or &&.
#    Promote to block after one clean week of warn-log review.
if match '(^|[;&]|\|\|)[[:space:]]*:?[[:space:]]*>[[:space:]]*[^&[:space:]/]' \
   && ! match '>[[:space:]]*/dev/(null|stderr|stdout)\b'; then
  warn_log "null-truncate" "$envelope"
fi

# 12. workspace-overwrite (WARN) — bare clobber into /workspace.
if match '>[[:space:]]*/workspace/[^[:space:]]'; then
  warn_log "workspace-overwrite" "$envelope"
fi

emit_pass
