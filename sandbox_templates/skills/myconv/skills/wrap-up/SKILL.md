---
name: wrap-up
description: Deliberate end-of-thread wrap-up — cross-check the repo's provenance trail before compact/clear. For complex, multi-issue threads only.
argument-hint: [--dry-run]
---

# Thread wrap-up

Before this thread is compacted or cleared, reconcile what actually happened against
the repo's provenance trail. Follow **"nearest file wins"** and **"ADRs are
append-only."**

> **When to run this:** deliberately, on threads that bounced across several issues and
> left context that needs cross-checking. A simple single-issue thread does **not** need
> this — skip it rather than manufacture busywork.

## Mode

Check `$ARGUMENTS` for `--dry-run`. In **dry-run mode**, treat *everything* as
propose-only: draft every change below — including the mechanical fixes normally applied
directly — and write **nothing**. It's the way to preview the full wrap-up on a thread
you're not ready to touch. Without the flag, run in normal mode (apply mechanical fixes,
propose direction-setting ones) per §10.

## 0. Detect what this repo actually keeps (do this first)

Look at the tree. This repo follows lean-core + opt-in, so **most repos will not have
every file below.** Only run the steps for machinery that exists.

- **Skip absent pieces silently** — do not report `ARCHITECTURE.md`, `work/`,
  `CHANGELOG.md`, `CODEOWNERS`, or `.claude/skills/` as "gaps" just because
  they're missing. Their absence is usually a deliberate choice.
- **Do not propose *adding* opt-in machinery** as part of a wrap-up. Standing up a new
  `work/` tier, proposal tier, or CI gate is a direction-setting change that deserves
  its own conversation (and often an ADR) — never a cleanup side-effect.

## 1. RECAP

List what actually happened this thread: files changed, decisions made, conventions
adopted or reversed, anything started then abandoned mid-approach, and any procedure
that recurred enough to be worth capturing.

If context is already thin and you're unsure what changed, don't guess — reconstruct
from git: diff against the thread's starting commit (`git log`, `git diff <start>..`).

## 2. AGENTS.md / CLAUDE.md

- Check the root `AGENTS.md` **and** any nested `AGENTS.md` in a directory touched this
  thread — is any rule, index link, or "where things live" entry now stale?
- For every `AGENTS.md` that was **changed or added**, confirm its sibling `CLAUDE.md`
  is present and is still the two-line `@AGENTS.md` stub — never real content, never
  missing. A new nested `AGENTS.md` with no `CLAUDE.md` beside it is a bug — **except
  under `templates/`** (or any example/placeholder tree), where a stub-less `AGENTS.md`
  is example content the adopter fills in by hand, not a bug.

## 3. ARCHITECTURE.md *(only if the repo keeps one)*

Does the map/boundaries still match reality after this thread? Update the
diagram/boundaries only — not implementation detail. If the repo deliberately has no
`ARCHITECTURE.md` (the layout is the architecture), skip this.

## 4. docs/adr/ *(or whatever this repo calls its decision log)*

- Did this thread make a decision that sets a new direction? If so it needs an ADR —
  check none was skipped.
- Never edit an Accepted ADR's Context/Decision. If a prior decision changed this
  thread, the fix is a **new** ADR that sets the old one's status to
  "Superseded by ADR-NNNN."
- Check for two ADRs contradicting each other on the same topic; resolve which is
  current.

## 5. Proposals *(only if the repo keeps a proposal tier)*

Wherever proposals live — `work/NNNN-slug/proposal.md`, a classic `docs/rfcs/`, or
somewhere else this repo chose: if a proposal discussed this thread reached a decision, note
that its rationale belongs in an ADR and its status should flip to
"Accepted → ADR-NNNN" (or Rejected) and out of active discussion.

## 6. work/NNNN-slug/ *(only if the repo tracks in-flight work in-repo)*

- If this thread's work merged or is done: distill anything durable first (decision
  rationale → ADR; reference knowledge → docs/ or a skill), then move the folder to
  `work/archive/` — or delete it if nothing durable remains. A stale `spec.md` left
  active poisons future agent searches.
- If still in flight, make sure `plan.md`/`notes.md` reflect where you *actually* left
  off, not the original plan.

## 7. .claude/skills/ *(only if present)*

For any skill touched, confirm its frontmatter `description` still matches what it does
— that description **is** the retrieval trigger, so a stale one means the skill stops
firing silently.

## 8. CHANGELOG.md *(only if the repo keeps one)*

Add an entry if anything user-visible shipped.

## 9. Traceability & write-back

- **Commits → decisions:** did commits made this thread reference the ADR/proposal they
  trace back to? Flag any direction-setting commit that doesn't.
- **Write-back loop:** was anything durable learned this thread (a gotcha, a convention,
  a procedure) that currently has no home? Propose where it should land — a new ADR, a
  new skill, or a line in `AGENTS.md` — so the next session doesn't re-derive it.

## 10. Apply vs. propose

- **Dry-run overrides this section:** if invoked with `--dry-run` (see *Mode* above),
  apply nothing — propose everything, mechanical fixes included.
- **Apply directly** only the mechanical, non-direction-setting fixes: a stale index
  link, a missing/malformed `CLAUDE.md` stub, an out-of-date skill description, a
  CHANGELOG line for something already shipped.
- **Draft and flag — do not auto-write** anything direction-setting: new ADRs,
  supersessions, proposal status changes. Present these for review before committing.
- Never push without approval.

## 11. Flag anything ambiguous

Instead of guessing: unsure whether a decision needs an ADR, whether a `work/` folder is
really done, or how to word a skill trigger — list these separately for me.

---

**End with a short summary:** files changed by category (AGENTS/CLAUDE, ADR,
`work/` — proposals included — skills, CHANGELOG), what you applied vs. what you
drafted, and open items needing my review before I clear.
