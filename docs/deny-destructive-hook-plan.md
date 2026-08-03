# `deny-destructive` PreToolUse hook

Ported from macolima. Source-of-truth for current invariants is
`../ARCHITECTURE.md` → "Security posture" / Agent tools row. This file is the
design-and-maintenance record for the `PreToolUse` hook that closes a class
of deny-list bypasses the prefix matcher cannot see.

## Status (2026-05-16)

**Ported from macolima.** Code, settings wiring, in-image install path, and
verify-sandbox tripwire all landed. End-to-end runtime behaviour pending
image rebuild + per-profile settings refresh.

What exists in this repo:

```
sandbox_templates/claude/hooks/
  deny-destructive.sh           # POSIX sh + jq, 14 rules, fail-open trap
  deny-destructive.test.sh      # 79-assertion host-side harness, all green
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

This is the same trade the rest of this repo accepts (see ARCHITECTURE.md note
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
| 3 | `rm-recursive` — any flag spelling carrying `-r`/`-R`/`--recursive` | block |
| 4 | `git-clean`           | block |
| 5 | `shred`               | block |
| 6 | `truncate`            | block |
| 7 | `dd-write` (`dd … of=…`) | block |
| 8 | `mkfs`                | block |
| 9 | `hook-tamper` (Bash)  — writes/redirects/chmod targeting `/usr/local/lib/claude-hooks/`, `/root/.claude/settings.json`, `/etc/claude/` | block |
| 9b | `git-hook-tamper` (Bash) — writes/redirects/`chmod` targeting any `.git/hooks/` | block |
| 10 | `cred-read` — any reference to `/root/.gemini`, `.config/{gh,glab-cli}`, `.claude/.credentials`, `.claude.json`, `.aws`, `.ssh` (also `~/` and `$HOME/` forms) | block |
| 10b | `cred-read` by bare credential filename (`oauth_creds.json`, `google_accounts.json`, `.credentials.json`) | block |
| 11 | `null-truncate` — bare `> file` clobber at command start | **warn** |
| 12 | `workspace-overwrite` — `>` into `/workspace/` | **warn** |
| 13 | `manifest-dep-add` (Edit/Write/MultiEdit) — a dependency **name not already in** `package.json` / `pyproject.toml` / `requirements*.txt` / `Pipfile` | block |
| 14 | `docs-install-cmd` (Edit/Write/MultiEdit) — an install command naming a package, written into `AGENTS.md`, `CLAUDE.md`, `SKILL.md`, `README.md`, `CONTRIBUTING.md`, `agent-notice.md`, `.cursorrules`, `*.mdc` | **warn** |
| 15 | `quarantine-tamper` (Edit/Write/MultiEdit, **by path**) — any write to the sandbox's own package-manager config: `/root/.config/pnpm/rc`, `/root/.npmrc`, `/usr/etc/npmrc` | block |
| 16 | `quarantine-weaken` (Edit/Write/MultiEdit, **by content**) — a payload setting `min-release-age` / `minimum-release-age` / `minimumReleaseAge` to `0` or to a suffixed value, in a project `.npmrc` / `pnpm-workspace.yaml` | block |
| 16b | `quarantine-touch` — any other payload naming those keys, or `registry=`, in the same files | **warn** |

### Rules 15–16 — resolution quarantine overrides

Added 2026-08-03, after the [dependency-guardrails
handoff](dependency-guardrails-handoff.md) analysis found that **writing a file
switched Gate 2 off**. npm/pnpm config precedence is
`cli > env > project > user > global`, so a per-directory `.npmrc` or
`pnpm-workspace.yaml` overrides the sandbox-wide age gate for installs run from
there. Rules 1–14 could not see it: the deny-list and rule 13 key on commands and
on *manifest* files, not on config.

The **path** tier (rule 15) is unconditional because those three files are
sandbox-owned — `/root/.config/pnpm/rc` is rewritten by `profile.sh ensure_state`
on every `up`, and `/usr/etc/npmrc` is baked into the image. A project needing
different settings uses its own `.npmrc`, which rule 16 governs. The pnpm file is
matched on full path, not basename: its basename is the bare word `rc`.

The **content** tier splits on whether a legitimate authoring path exists.
Zeroing the gate has none. Neither does a suffixed value, which is *worse* than
off — pnpm computes `value*60*1e3`, so `7d` yields `NaN` → `Invalid Date` and
**every version is rejected**, failing closed and presenting as a broken
registry. Strengthening the window is legitimate and common (this repo's own
plans tell people to commit `10080`), so it warns instead; a naive block there
would fire on correct work and train people to route around the hook. A shell
redirect bypasses this arm entirely, which is the second reason not to over-block
— the warn log is the promotion path.

Detection is layered, and only this rule is preventive: `depaudit`'s **N03**
finds these files statically in any repo, and `verify-sandbox.sh`'s G10 sweep
compares them against the live in-container baseline. `with-egress.sh` records
any override in the install window's audit record, so a window that resolved
packages under a weakened gate cannot later read as a clean quarantined install.

### Rules 13–14 — dependency guardrails

Added by [`work/0001-dependency-guardrails`](../work/0001-dependency-guardrails/plan.md)
phase 1 (T04, T05). Both close paths no Bash matcher can see.

**Rule 13 exists because an install command is not the only way to install.** An agent
that writes a dependency line into a manifest and then runs an *allowed* build command
(`uv run`, `pnpm run build`, `make`, `just`) has installed a package without ever issuing
an install command. Every one of those runners is on the **allow** list.

It blocks a dependency being **added**, not a manifest being **edited** — the distinction
that decides whether the rule survives contact. The dependency names already present in
the file *on disk* are subtracted from the names in the payload; only genuinely new names
block. That is what lets a version bump, a `scripts` change, or a metadata edit through.
Comparing against the file rather than against `old_string` is deliberate: an Edit payload
is only a fragment, so `old_string` cannot tell you what the manifest already contains.

`dep_names()` normalises on `{}[],` before matching, because a line-oriented match misses
every compact manifest (`{"a":"^1","b":"^2"}`, `dependencies = ["x>=1", "y>=2"]`). A missed
*old* name is the dangerous direction — it makes an existing dependency look newly added
and fires the rule on a version bump.

**Rule 14 warns rather than blocks, deliberately.** Instruction files are executable
surfaces: an install command written into one is run by the next agent and pasted by the
next human. But documentation *about* dependency rules legitimately quotes install
commands — `sandbox_templates/common/agent-notice.md` does exactly that — so blocking
would fire on correct writing. Bare and lockfile forms (`npm ci`, `uv sync --frozen`,
`pip install --require-hashes -r`) are ignored: the pattern requires a non-flag argument,
i.e. an actual package name. Review the warn log before considering promotion to block.

**The four version-bump cases in the test harness are merge gates.** If any of them ever
fails, rule 13 is a false-positive generator and gets reverted rather than shipped — a
rule that fires on routine edits is switched off within a week, and then there is no rule
at all.

Rule 3 exists because `permissions.deny` carries `Bash(rm -rf:*)`, and that is
a *literal prefix*: `rm -r -f`, `rm -fr`, `rm -Rf`, and `rm --recursive` all
walk past it. The matcher can't close that; the hook can. Non-recursive
`rm file` / `rm -f file` still pass — this targets tree deletion only.

Rule 9b closes the escalation that an allow rule like `Bash(git commit *)`
opens: git executes `.git/hooks/*` on commit, so a written-then-`chmod +x`'d
hook script turns the next pre-approved commit into arbitrary execution.
`chmod` is the load-bearing verb — an unexecutable hook file is inert.

For `tool_name in (Edit, Write, MultiEdit)`: `realpath -m` the
`file_path`, block if the resolved path is under
`/usr/local/lib/claude-hooks/`, exactly `/root/.claude/settings.json`,
under `/etc/claude/`, or under any `.git/hooks/`.

**Warn behaviour**: append a JSON-line entry to
`/root/.cache/deny-destructive.log` with `{ts, rule, envelope}`
(timestamp + full envelope, not just the command — required to evaluate
the warn→block promotion review), so the command reads back at
`.envelope.tool_input.command`. Return `{}`, exit 0.

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
docker exec ai-sandbox-<profile> cat /root/.cache/deny-destructive.log \
  | jq -r '[.ts, .rule, .envelope.tool_input.command] | @tsv'
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
