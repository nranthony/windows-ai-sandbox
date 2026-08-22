#!/bin/sh
# deny-destructive: PreToolUse hook, shared by TWO agents.
#
# Inspects the full tool envelope on stdin and either passes through or blocks.
# One rule table, two dialects — chosen by `--dialect=`, defaulting to claude:
#
#   claude       (https://code.claude.com/docs/en/hooks.md)
#     in   {"tool_name":"Bash","tool_input":{"command":"…"}}
#     pass {}
#     deny {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#            "permissionDecision":"deny","permissionDecisionReason":"…"}}
#
#   antigravity  (`agy`; protojson, camelCase — see work/0010)
#     in   {"toolCall":{"name":"run_command","args":{"CommandLine":"…"}},…}
#     pass {"decision":"allow"}
#     deny {"decision":"deny","reason":"…"}
#
# The antigravity envelope is TRANSLATED into the claude shape immediately
# after it is read, so everything below the adapter is one shared rule table.
# Adding a rule protects both agents; that is the entire point of the split.
#
# Closes the deny-list bypass class where the prefix matcher in each agent's
# static permission list cannot see destructive flags (find -delete, dd of=,
# etc.) or path targets. See docs/deny-destructive-hook-plan.md.
#
# ---------------------------------------------------------------------------
# FAILURE POSTURE DIFFERS BY DIALECT, DELIBERATELY. Do not unify it.
#
#   claude       fail-OPEN. A broken hook must not brick the agent, and it is
#                safe to fail open here because permissions.deny in
#                claude-settings.json is the primary layer and this hook is
#                defence-in-depth on top of it.
#
#   antigravity  fail-CLOSED. Measured, not assumed (work/0010 Phase 0): agy
#                already blocks the tool call when a hook exits non-zero,
#                times out, or prints unparseable stdout. Emitting `{}` is a
#                DENY there, not a pass. So the harness is fail-closed whatever
#                this script does; the trap only replaces a raw protojson
#                error with a reason a human can read.
#
# The verify-sandbox.sh tripwire and the audit probes catch a permanently
# broken hook within one cycle in both directions.
# ---------------------------------------------------------------------------
#
# windows-ai-sandbox note: container runs as root (UID 0) under rootless
# Docker userns=host. Protected paths are /root/... here, not /home/agent/...
# The kernel write-protect that macolima relies on (root-owned 0755 file,
# agent UID 1000) does NOT apply here — the agent IS root. The Edit and Bash
# tamper rules below are the *only* enforcement layer for the hook script
# itself; this is defence-in-depth on top of the static deny lists, not a hard
# kernel boundary. Image rebuild restores the canonical hook on every up.

set -u

# ---------- dialect ----------
# Explicit flag, not sniffing: hooks.json passes --dialect=antigravity, and an
# envelope that fails to match its declared dialect is a bug we want to see as
# a denial rather than to paper over by guessing.
DIALECT=claude
for _arg in "$@"; do
  case "$_arg" in
    --dialect=*) DIALECT=${_arg#--dialect=} ;;
  esac
done
case "$DIALECT" in
  claude|antigravity) ;;
  *) DIALECT=claude ;;
esac

emit_trap() {
  if [ "$DIALECT" = antigravity ]; then
    printf '{"decision":"deny","reason":"deny-destructive: internal error (fail-closed)"}\n'
  else
    printf '{}\n'
  fi
  exit 0
}
trap emit_trap EXIT INT HUP TERM

LOG="${DENY_DESTRUCTIVE_LOG:-/root/.cache/deny-destructive.log}"

emit_pass() {
  if [ "$DIALECT" = antigravity ]; then
    # NOT `{}` — measured: agy reads an absent `decision` as DENY, so the
    # claude pass-through would block every tool call. `allow` here does not
    # bypass agy's own permissions.deny either (also measured); it means only
    # that this hook has no objection.
    printf '{"decision":"allow"}\n'
  else
    printf '{}\n'
  fi
  trap - EXIT; exit 0
}

emit_block() {
  rule=$1; msg=$2
  reason="deny-destructive: ${rule}: ${msg}"
  # jq builds the envelope so reason strings with quotes/newlines stay safe.
  # `-c` keeps output compact (single line) — easier for downstream greps and
  # marginally lighter for the harness to parse.
  if [ "$DIALECT" = antigravity ]; then
    printf '%s' "$reason" | jq -Rsc '{decision:"deny",reason:.}'
  else
    printf '%s' "$reason" \
      | jq -Rsc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:.}}'
  fi
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
if [ -z "$envelope" ]; then
  # Empty stdin is a harness bug, not a tool call. Claude passes (fail-open,
  # per the posture note above); antigravity refuses, because an empty read
  # here and a legitimate "no opinion" are indistinguishable and only one of
  # them is safe to guess.
  if [ "$DIALECT" = antigravity ]; then
    emit_block "empty-envelope" "hook received no input; refusing the tool call"
  fi
  emit_pass
fi

# ---------- input adapter: antigravity -> claude shape ----------
# Everything below this point speaks one dialect. Tool-name and argument-key
# mapping was read off live payloads (work/0010 Phase 0), not from docs.
#
# An UNMAPPED tool passes. That is a reversal of the pre-measurement plan,
# which said an unknown tool should deny: the matcher in hooks.json is "*", and
# agy's tool surface is large and moves (browser_*, mcp(...), search_web,
# subagent management). Denying everything unmapped does not harden the agent,
# it stops it booting — and the static permissions.deny list in
# antigravity-settings.json, which no workspace file can reach, is the layer
# that has to be complete. `tools-check` watches for new tool names that carry
# a command or a path so this mapping cannot silently fall behind.
if [ "$DIALECT" = antigravity ]; then
  # Fail CLOSED on anything we cannot parse. `|| emit_pass` here — the claude
  # idiom used everywhere below — would be a hole: an envelope shaped so that
  # jq errors would sail through as an allow. agy blocks the call anyway when a
  # hook misbehaves, so this only replaces a raw protojson error with a reason.
  if ! printf '%s' "$envelope" | jq -e . >/dev/null 2>&1; then
    emit_block "malformed-envelope" "hook received input that is not valid JSON; refusing the tool call"
  fi
  envelope=$(printf '%s' "$envelope" | jq -c '
    (.toolCall.name // "") as $n | (.toolCall.args // {}) as $a |
    if   $n == "run_command"          then {tool_name:"Bash",  tool_input:{command:    ($a.CommandLine // "")}}
    elif $n == "write_to_file"        then {tool_name:"Write", tool_input:{file_path:  ($a.TargetFile  // ""), content:    ($a.CodeContent        // "")}}
    elif $n == "replace_file_content" then {tool_name:"Edit",  tool_input:{file_path:  ($a.TargetFile  // ""), new_string: ($a.ReplacementContent // "")}}
    elif $n == "view_file"            then {tool_name:"Read",  tool_input:{file_path:  ($a.AbsolutePath // "")}}
    elif $n == "grep_search"          then {tool_name:"Read",  tool_input:{file_path:  ($a.SearchPath   // "")}}
    else {} end' 2>/dev/null) \
    || emit_block "adapter-error" "hook could not translate the antigravity envelope; refusing the tool call"
fi

tool_name=$(printf '%s' "$envelope" | jq -r '.tool_name // empty' 2>/dev/null) || emit_pass
[ -z "$tool_name" ] && emit_pass

# ---------- Read ----------
# Claude reaches this branch only if someone registers the hook on Read; its
# credential denials live in permissions.deny (Read(**/.env) and friends).
# antigravity has no equivalent path-scoped static rule, so for `agy` this
# branch IS the read control — and it is the same list either way.
if [ "$tool_name" = "Read" ]; then
  rfp=$(printf '%s' "$envelope" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  [ -z "$rfp" ] && emit_pass
  rrp=$(realpath -m "$rfp" 2>/dev/null) || rrp="$rfp"
  case "$rrp" in
    */.env|*/.env.*|*.pem|*.key|*/id_rsa*|*/id_ed25519*|*/.credentials*)
      emit_block "cred-read" "read of a secret file ($(basename "$rrp")) is denied; ask the user for what you need from it" ;;
    /root/.gemini/*|/root/.claude/.credentials*|/root/.claude.json|/root/.config/gh/*|/root/.config/glab-cli/*|/root/.aws/*|/root/.ssh/*)
      emit_block "cred-read" "read of the agent's own credential store ($rrp) is denied; ask the user to run this" ;;
  esac
  emit_pass
fi

# ---------- Edit / Write / MultiEdit ----------
case "$tool_name" in
  Edit|Write|MultiEdit)
    fp=$(printf '%s' "$envelope" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    [ -z "$fp" ] && emit_pass
    # realpath -m: canonicalise without requiring existence.
    rp=$(realpath -m "$fp" 2>/dev/null) || rp="$fp"
    case "$rp" in
      /usr/local/lib/claude-hooks/*|/usr/local/lib/sandbox-hooks/*)
        emit_block "hook-tamper" "edit to in-image hook script is denied; ask the user to rebuild" ;;
      /root/.claude/settings.json)
        emit_block "hook-tamper" "edit to live settings.json is denied; ask the user to run this" ;;
      /etc/claude/*)
        emit_block "hook-tamper" "edit under /etc/claude/ is denied; ask the user to run this" ;;
      /root/.gemini/config/hooks.json|/root/.gemini/antigravity-cli/settings.json)
        # The two files that ARE the antigravity policy: the hook registration
        # and the static permissions.allow/deny/ask list.
        emit_block "hook-tamper" "edit to the live antigravity policy ($rp) is denied; ask the user to run 'profile.sh <p> reset-antigravity'" ;;
      */.agents/hooks.json|*/.agent/hooks.json|*/_agents/hooks.json|*/_agent/hooks.json)
        # MEASURED BYPASS, not a hypothetical (work/0010 Phase 0, test G).
        # agy discovers workspace customizations under these four directory
        # names and merges hooks BY NAME, with the workspace copy outranking
        # the global one. A file containing
        #     {"sandbox-guardrails": {"enabled": false}}
        # in any attached workspace disables the global guardrail outright —
        # confirmed: `loaded 1 named hooks from 2 hooks.json file(s)` and the
        # denied command then ran. The workspace is the agent's own writable
        # bind mount, so this needs no privilege at all.
        #
        # Blocking the write is the control here. The static deny list in
        # antigravity-settings.json is the backstop that survives it, because
        # no workspace file can reach settings.json — which is exactly why the
        # hard denials live there and not only here.
        emit_block "agy-workspace-hook-tamper" "writing a workspace hooks.json is denied: agy merges these OVER the sandbox guardrail by name, so this file can switch it off. If a project genuinely needs its own hook, that is the user's call to make." ;;
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
      # run by the next agent and pasted by the next human. The fetch-and-run
      # forms (npx, npm/pnpm exec, yarn dlx, bunx, bun x) and `pip download`
      # count as install commands here for the same reason they are denied in
      # permissions.deny: each resolves a package from a registry and runs it.
      # `pnpm dlx` was covered from the start and its five siblings were not,
      # so `bunx some-cli` in a README went unlogged while the identical
      # `pnpm dlx some-cli` was flagged. WARN, not block —
      # documentation about dependency rules legitimately quotes install
      # commands (this repo's own agent-notice.md does), so blocking would fire
      # on correct writing. Reviewed from the warn log before any promotion to
      # block. Bare/lockfile forms (`npm ci`, `uv sync --frozen`) are ignored:
      # the trailing pattern requires a non-flag argument, i.e. a package name.
      AGENTS.md|CLAUDE.md|GEMINI.md|SKILL.md|README.md|CONTRIBUTING.md|agent-notice.md|.cursorrules|*.mdc)
        if printf '%s' "$payload" | grep -Eq '(npm[[:space:]]+(i|install|add|exec)|\bnpx\b|pnpm[[:space:]]+(add|install|dlx|exec)|yarn[[:space:]]+(add|dlx)|bun[[:space:]]+(add|x)|\bbunx\b|pip3?[[:space:]]+(install|download)|uv[[:space:]]+add|uv[[:space:]]+pip[[:space:]]+install|pipx[[:space:]]+install|poetry[[:space:]]+add|cargo[[:space:]]+(install|add)|go[[:space:]]+(install|get))[[:space:]]+[^-[:space:]]' 2>/dev/null; then
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
if match '(>|>>|\btee\b|\bsed\b|\bchmod\b|\bchown\b|\bmv\b|\bcp\b|\brm\b|\bln\b)[^|;&]*(/usr/local/lib/(claude|sandbox)-hooks/|/root/\.claude/settings\.json|/etc/claude/|/root/\.gemini/config/hooks\.json|/root/\.gemini/antigravity-cli/settings\.json)'; then
  emit_block "hook-tamper" "write/modify of hook or settings file is denied; ask the user to rebuild"
fi

# 9c. agy-workspace-hook-tamper (Bash side) — the shell route into the measured
#     workspace override. The Edit/Write case above only sees the write tools;
#     a redirect, `tee`, `sed -i`, `cp` or `mv` reaches the same file. Kept
#     unanchored so a relative `.agents/hooks.json` counts, and `mkdir -p` is
#     included because the directory usually does not exist yet — creating it
#     is the tell.
if match '(>|>>|\btee\b|\bsed\b|\bmv\b|\bcp\b|\bln\b|\bmkdir\b|\binstall\b)[^|;&]*(\.agents?|_agents?)/hooks\.json' \
   || match '\bmkdir\b[^|;&]*[[:space:]](\.agents?|_agents?)([[:space:]]|/|$)'; then
  emit_block "agy-workspace-hook-tamper" "creating a workspace hooks.json is denied: agy merges these OVER the sandbox guardrail by name, so this file can switch it off; ask the user to run this"
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
