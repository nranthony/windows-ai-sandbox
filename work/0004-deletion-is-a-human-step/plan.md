# Deletion is a human step — the hook blocks bulk shapes, not the verb

**Status:** Not started. Parked for revisit. Raised 2026-08-12 from an in-container
episode; captured here because the hook and its instruction layer are both
host-side artifacts of *this* repo.

**Exit rule:** delete this folder, or move to [`docs/_archive/`](../../docs/_archive/),
when the work merges.

**Security-sensitive.** Touches `sandbox_templates/claude/hooks/deny-destructive.sh`
and `sandbox_templates/common/agent-notice.md`. Any change here needs a security
impact line in the commit, `bash sandbox_templates/claude/hooks/deny-destructive.test.sh`
green (currently 95/95), and `scripts/profile.sh <p> verify`.

---

## Origin — what actually happened

Reported by a Fable 5 session working inside a profile. Nothing was covertly
bypassed; the sequence was:

1. A Stage A subagent tried `git rm -r` on two skill directories.
2. The hook blocked it. Rule 3 (`rm-recursive`,
   `deny-destructive.sh:250`) matches a short-flag cluster containing `r` after
   any `rm` token — `git rm -r` trips it, and the header comment at line 248
   already records this as a *deliberate* false positive.
3. The agent then removed the eight files individually with plain
   `git rm <file>`, which nothing blocks, and git pruned the emptied parent
   directories on its own.
4. It reported the deviation rather than concealing it, and the deletions were
   pre-approved — named explicitly in the plan and in the handoff decision.

The authorization chain held. What the episode exposes is a **shape gap**: the
hook enforces "no bulk deletion" but not "deletion is a human step." Anything
deletable in bulk is deletable as N single-target calls, and an agent under
instruction to complete approved work will find that decomposition without ever
violating the letter of the rule.

That generalizes past deletion. **Every bulk-shape block in this hook is
decomposable into per-item calls** — the same reasoning applies to `find -exec`
(rule 2), and would apply to any future "wide blast radius" rule. Deciding this
one is deciding the class.

The incident repo is not this one — `git log --diff-filter=D` over `*skills*`
here is empty. Only the hook and the notice block live here.

## What the hook covers today

Read before designing: several of the "gaps" proposed in the source thread are
already handled, and mis-scoping the change is how a rule ships inverted.

| Verb | Status today |
|---|---|
| `rm -rf` and every flag spelling | **blocked** — rule 3, spelling-independent |
| `git rm -r` | **blocked** — rule 3, deliberate false positive |
| `git clean` | **blocked** — rule 4 |
| `truncate` | **blocked** — rule 6 |
| `shred`, `dd of=`, `mkfs` | **blocked** — rules 5, 7, 8 |
| `git reset --hard`, `git rebase` | **denied** in `claude-settings.json` — but by *literal prefix*, so `git -C <dir> reset --hard` walks past it (the exact bypass class rule 3 was written to close) |
| `: > file` / bare `> file` clobber | **WARN only** — rule 11, `deny-destructive.sh:316`. Its own comment says "promote to block after one clean week of warn-log review." That review appears never to have happened. |
| clobber into `/workspace` | **WARN only** — rule 12 |

Genuine, uncovered:

- bare `git rm <file>` — the exact route taken
- `git checkout -- <path>` / `git restore <path>` — discarding uncommitted work
  is destruction with no undo, and reads as an ordinary navigation verb
- `git stash drop` / `git stash clear`
- `git branch -D`
- `unlink <file>`
- plain non-recursive `rm <file>` / `rm -f <file>`
- `cp /dev/null file`, `mv` over an existing path
- **Write/Edit** emptying or wholesale-rewriting a file — no shell command
  involved at all, so no Bash rule can see it

## The design choice: `ask`, not a wider `deny`

The substantive proposal from the thread, and the reason this is a work item
rather than a one-line patch:

> Return `"permissionDecision": "ask"` for these instead of `deny`. A hard deny
> makes legitimately approved work impossible and invites exactly the
> workaround-hunting observed. `ask` routes every deletion through the human
> while keeping the work possible. Reserve `deny` for the truly-never cases
> (`rm -rf`, `dd of=`, hook-file edits).

This is consistent with the hook's own stated philosophy at line 186: blocking
legitimate work "would fire on correct work and **train evasion**." Rule 13's
WARN tier exists for precisely that reason. `ask` is the missing middle tier
between WARN (invisible until someone greps the log) and DENY (absolute).

It is also the first weakening-shaped change to a fail-safe file, so it needs
its rationale on the record either way.

### What implementing `ask` costs

- `emit_block()` (`deny-destructive.sh:35`) hardcodes `permissionDecision:"deny"`.
  Needs a sibling `emit_ask()` — same jq envelope, different decision string.
  Keep the `deny-destructive: <rule>: <msg>` reason prefix so log greps and the
  audit probe keep working.
- `deny-destructive.test.sh` asserts `pass|deny` (helper at line 20). Extending
  to a third decision touches every existing assertion's contract. Do this as
  its own commit, green at 95/95, before adding a single new rule.
- **Open question, must be answered first:** what does `ask` do when there is no
  human at the prompt — a subagent, a `--print` run, a cron/scheduled run? If it
  silently resolves to *allow* in any of those, `ask` is strictly weaker than
  today's posture on the paths that matter most, and the whole approach is dead.
  Verify empirically against the harness before writing any rule.

## Instruction-layer half

The hook is one layer; the sandbox-managed notice is the other. Current wording
in `sandbox_templates/common/agent-notice.md:26`:

> **Destructive commands are hook-blocked.** … Don't look for a bypass — that's
> exactly what it catches.

That is a *don't-fight-the-block* rule, and the episode satisfied it literally:
single-file `git rm` was never blocked, and the deletion was plan-approved. If
the intent is per-execution confirmation **even inside an approved plan**, that
has to be stated, not implied. Proposed line:

> **File deletions — every one, single files included, even when an approved
> plan names them — are proposed first: list the exact paths and wait.**

Notes on landing it:

- The canonical file is `sandbox_templates/common/agent-notice.md`; it reaches
  profiles via `scripts/sync-agent-notice.sh`, which `profile.sh:517` runs on
  every `up` into `<profile>/claude-home/CLAUDE.md`. Editing the canonical file
  is the whole change — do not hand-edit a profile copy.
- The rule only holds for subagents if it is carried into subagent prompts too.
  In this episode the orchestrator explicitly instructed the agent to use
  `git rm`, on the strength of the human's approval. An instruction the
  orchestrator can override at spawn time is not a guarantee.
- Instruction-layer alone is the cheap option and may be sufficient. It is also
  the one that just demonstrably failed to bind. Weigh accordingly.

## Decisions needed

1. **`ask` or wider `deny`?** Blocked on the no-human-present question above.
2. **Which verbs get which tier?** Suggested split, to be argued not assumed:
   `ask` for `git rm`, `git checkout --`, `git restore`, `git stash drop|clear`,
   `git branch -D`, `unlink`, plain `rm`; `deny` unchanged for the existing
   rules 1–10.
3. **Promote rule 11 (`null-truncate`) to block?** Its own comment says to, after
   a warn-log review that has not happened. Read
   `/root/.cache/deny-destructive.log` in a live profile first — if it is quiet,
   promotion is nearly free and closes the truncation route named in the thread.
4. **Does plain `rm <file>` really go to `ask`?** This is the highest-friction
   item on the list — build scratch, temp files, and `.pyc` cleanup all hit it.
   Likely needs a path carve-out (`/tmp`, `.venv`, build dirs) or it trains
   exactly the evasion rule 13's comment warns about.
5. **Write/Edit destructive rewrite — in scope or not?** Hooking it is possible
   (the Edit/Write arm already exists, lines ~99–204) but noisy: distinguishing
   "rewrote the file" from "emptied the file" needs a payload heuristic, and
   false positives here block ordinary editing. Default answer is no; record why.
6. **Does macolima get the same treatment?** The hook is shared in shape but the
   protected paths differ (`/home/agent/…` vs `/root/…`) and the kernel
   write-protect exists there. Golden rule 3 — cross-check, never blind-copy.

## Investigation to do first

- Answer decision 1 empirically: fire an `ask` envelope through a subagent and a
  `--print` run, and record what the harness does with it.
- Pull the warn log from a live profile for rules 11 and 12 (decision 3).
- Re-read `deny-destructive.test.sh` lines 20–45 to scope the three-decision
  assert-helper change.
- Check whether `permissions.deny`'s literal-prefix entries for
  `git reset --hard` / `git rebase` should move into the hook as
  spelling-independent matches, since that is the same defect rule 3 was created
  to fix.

## Non-goals

- Re-litigating the episode. The chain was intact, the deviation was reported,
  and the deletions were approved. This is a rule-shape gap, not a conduct issue.
- Any change to the existing rules 1–10 semantics.
- Anything about the Bash allow-list. `git rm` is not on it; that is not what
  made this reachable.
