# `deny-destructive` PreToolUse hook

Ported from macolima. Source-of-truth for current invariants is
`../CLAUDE.md` → "Security Posture" / Permissions row. This file is the
design-and-maintenance record for the `PreToolUse` hook that closes a class
of deny-list bypasses the prefix matcher cannot see.

## Status (2026-05-16)

**Ported from macolima.** Code, settings wiring, in-image install path, and
verify-sandbox tripwire all landed. End-to-end runtime behaviour pending
image rebuild + per-profile settings refresh.

What exists in this repo:

```
sandbox_templates/claude/hooks/
  deny-destructive.sh           # POSIX sh + jq, 10 rules, fail-open trap
  deny-destructive.test.sh      # 35-assertion host-side harness, all green
Dockerfile                      # COPY + chmod 0755 to /usr/local/lib/claude-hooks/
sandbox_templates/claude/claude-settings.json     # top-level "hooks" block (Bash + Edit|Write|MultiEdit)
scripts/verify-sandbox.sh       # tripwire: file invariants + behavioural deny probe
```

What's pending (after this port lands):

- `scripts/profile.sh build` — rebuild base image with the hook baked in.
- `scripts/profile.sh <p> rebuild` — per running profile, picks up new image.
- `scripts/profile.sh <p> reset-settings` — re-seed live `settings.json`
  with the new `hooks` block. `init-profile-state.sh` only seeds settings
  on first up; existing profiles need explicit re-seed.
- End-to-end smoke: ask the agent to `find /tmp/<sentinel> -delete` against
  a sentinel — confirm block reason in transcript; sentinel survives.

## Key difference from macolima

**This repo runs the container as root (UID 0)** under rootless Docker
`userns=host`. macolima's `agent` user (UID 1000) doesn't exist here.

Consequences:

- Protected paths are `/root/.claude/settings.json` (not
  `/home/agent/.claude/settings.json`).
- Default warn-log path is `/root/.cache/deny-destructive.log`.
- **The kernel write-protect that macolima relies on does NOT apply.**
  macolima's hook script is root-owned 0755 inside the image, and agent
  (UID 1000) cannot write to it via any tool because the kernel rejects
  the syscall. Here, the agent IS root inside the container, so the
  Edit-side and Bash-side `hook-tamper` rules are the **only** layer
  protecting the hook script and `settings.json` from in-tool modification.
  Defence-in-depth on `permissions.deny`, not a hard kernel boundary.
  Image rebuild restores the canonical hook on every up — drift is
  ephemeral.

This is the same trade the rest of this repo accepts (see CLAUDE.md note
on why we don't flip to non-root inside the container under `userns=host`
— it would break workspace bind-mount writes via subuid remapping).

## Context — why the hook exists

A field session in macolima surfaced a bypass: agent hit `Bash(rm -rf:*)`
deny three times, pivoted to `find <path> -depth -delete`, and announced
the workaround. `Bash(find:*)` is allow-listed for legitimate search use,
and the prefix matcher in `permissions.deny` cannot see destructive flags
(`-delete`, `-exec`, `-execdir`, `-ok`) mid-command. Same class covers
`git clean -fdx`, `shred`, `truncate`, `dd of=`, `mkfs`, and "truncate via
redirection" idioms (`: > file`, `> /workspace/important`).

The fix the matcher structurally can't deliver is a `PreToolUse` hook
that inspects the full command string against a regex ruleset. Hooks run
in the harness, upstream of tool dispatch — the model is downstream and
cannot bypass at call time.

## Hook output contract

Follows Claude Code's current `PreToolUse` contract:

- **Block**:
  ```json
  {"hookSpecificOutput":{
     "hookEventName":"PreToolUse",
     "permissionDecision":"deny",
     "permissionDecisionReason":"deny-destructive: <rule>: <message>"}}
  ```
- **Allow / pass-through**: `{}` on stdout, exit 0.
- **Fail-open** on any script error: `trap 'printf "{}\n"; exit 0'` — a
  broken hook must not brick the agent. The `verify-sandbox.sh` tripwire
  catches a permanently-broken hook within one cycle.

## Ruleset

The hook reads the tool-call JSON envelope on stdin and returns a decision
on stdout. Pass-through (`{}`) for any envelope that doesn't match a rule.
For `tool_name == "Bash"`, normalise the command (lowercase, strip leading
`sudo`/`time`/`nice`/`ionice`), then match in order; first hit wins.

| # | Rule | Disposition |
|---|---|---|
| 1 | `find-delete`         | block |
| 2 | `find-exec` (destructive subcommands only: rm/mv/dd/truncate/shred/tee/chmod/chown) | block |
| 3 | `git-clean`           | block |
| 4 | `shred`               | block |
| 5 | `truncate`            | block |
| 6 | `dd-write` (`dd … of=…`) | block |
| 7 | `mkfs`                | block |
| 8 | `hook-tamper` (Bash)  — writes/redirects/chmod targeting `/usr/local/lib/claude-hooks/`, `/root/.claude/settings.json`, `/etc/claude/` | block |
| 9 | `null-truncate` — bare `> file` clobber at command start | **warn** |
| 10 | `workspace-overwrite` — `>` into `/workspace/` | **warn** |

For `tool_name in (Edit, Write, MultiEdit)`: `realpath -m` the
`file_path`, block if the resolved path is under
`/usr/local/lib/claude-hooks/`, exactly `/root/.claude/settings.json`, or
under `/etc/claude/`.

**Warn behaviour**: append a JSON-line entry to
`/root/.cache/deny-destructive.log` with `{ts, rule, tool_input}`
(timestamp + full envelope, not just the command — required to evaluate
the warn→block promotion review). Return `{}`, exit 0.

## Maintenance

### When extending the ruleset

Every new destructive primitive needs **all three**:

1. New rule in `sandbox_templates/claude/hooks/deny-destructive.sh`.
2. New positive + negative assertions in
   `sandbox_templates/claude/hooks/deny-destructive.test.sh`. Run on host pre-commit
   (`bash sandbox_templates/claude/hooks/deny-destructive.test.sh`) — must stay green.
3. If the rule adds a new path constant, an extension to the
   `verify-sandbox.sh` probe so the new constant is asserted at runtime.

### Warn-log review (warn → block promotion)

Two rules ship as **warn**: `null-truncate` and `workspace-overwrite`.
Both are high-variance — there are legitimate uses (`: > file` to
truncate a log the agent owns; `> /workspace/build/output.json` for
build artifacts). Promote to `block` only after one clean review week:

```bash
# Inside an active profile
docker exec ai-sandbox-<profile> cat /root/.cache/deny-destructive.log | jq .
```

If zero false positives over a week of active development, flip the
`warn_log` call to `emit_block` and add the corresponding positive
assertion.

## Out of scope

- **Per-profile user-customizable hooks** via `claude-home/hooks/`.
  Premature flexibility; revisit if a project actually needs project-
  specific blocks.
- **Hardening parallel paths** (agent writes a Python script via Edit,
  runs it via allowed `python:*`). The kernel + proxy + caps remain the
  documented boundary for that case.
- **Defeating shell-alias bypasses** (`alias fdel='find -delete'`). The
  matcher-level prefix denies in `permissions.deny` are the primary
  filter; the hook is content-aware on the unaliased command string the
  harness sees.
