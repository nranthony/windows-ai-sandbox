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

**This is not a substitute for the repo's own gates.** A wrap-up that finds nothing can
still leave stale documents shipped: §2 *reads* the repo's gate, it never runs it.

**If these instructions are wrong, stale, or a bad fit for this repo:** file it with
`/myconv:report-skill-feedback` at the moment you deviate, before working around it.

## Mode

Check `$ARGUMENTS` for `--dry-run`. In **dry-run mode**, treat *everything* as
propose-only: draft every change below — including the mechanical fixes normally applied
directly — and write **nothing**. It's the way to preview the full wrap-up on a thread
you're not ready to touch. Without the flag, run in normal mode (apply mechanical fixes,
propose direction-setting ones) per §12.

## 0. Detect what this repo actually keeps (do this first)

Look at the tree. This repo follows lean-core + opt-in, so **most repos will not have
every file below** — only run the steps for machinery that exists. But decide *which*
state you are in first, and there are three of them, not two:

- **Not kept.** Skip it silently: absence is usually a deliberate choice, not a gap.
  Never report a missing `ARCHITECTURE.md`, `work/`, `CHANGELOG.md`, `CODEOWNERS` or
  skills directory as a finding.
- **Kept under another name or path.** Before skipping anything, check whether something
  plays its role: read the root `AGENTS.md` / index for a decision log, a work tier, a
  skills or guides directory, and look at what the tree actually holds. **Never
  configured is a skip; present under a different name is a miss.** Report the mapping
  you inferred.
- **Could not locate.** Searched, nothing conclusive. Say so, and **name the paths you
  checked**. A quiet skip here is how a section silently does not run at all.

**Do not propose *adding* opt-in machinery** as part of a wrap-up. Standing up a new
`work/` tier, proposal tier, or CI gate is a direction-setting change that deserves
its own conversation (and often an ADR) — never a cleanup side-effect.

**Print the tier map before §1** — one row per tier: tier → the path found, "not kept",
or "could not locate (checked: …)". Detecting silently leaves the operator unable to see
what will *not* be checked, and a report listing only what passed reads as full coverage.
A skip is not a pass.

## 1. RECAP

List what actually happened this thread: files changed, decisions made, conventions
adopted or reversed, anything started then abandoned mid-approach, and any procedure
that recurred enough to be worth capturing.

If context is already thin and you're unsure what changed, don't guess — reconstruct
from git: diff against the thread's starting commit (`git log`, `git diff <start>..`).

## 2. The repo's own change gate

**Does this repo define a gate for the files this thread touched?** Many state one in
`AGENTS.md` or a contributing doc — checks that must pass, documents that must be updated
together, a commit-message convention. **Enumerate every clause and check each one; do
not run them.** This is the highest-yield section on any repo mature enough to have
written a gate down, because those clauses name the specific documents a generic wrap-up
cannot guess at. If the repo states no gate, say so and move on.

## 3. AGENTS.md / CLAUDE.md

- Check the root `AGENTS.md` **and** any nested `AGENTS.md` in a directory touched this
  thread — is any rule, index link, or "where things live" entry now stale?
- For every `AGENTS.md` that was **changed or added**, confirm its sibling `CLAUDE.md`
  is present and is still the two-line `@AGENTS.md` stub — never real content, never
  missing. A new nested `AGENTS.md` with no `CLAUDE.md` beside it is a bug — **except
  under `templates/`** (or any example, fixture, or test-corpus tree), where a stub-less
  `AGENTS.md` is example content the adopter fills in by hand, not a bug.

## 4. ARCHITECTURE.md *(only if the repo keeps one)*

Does the map/boundaries still match reality after this thread? Update the
diagram/boundaries only — not implementation detail — **but including any enumeration
the map carries**: file lists, counts, command inventories, named test suites. Those rot
silently because they read as prose. If the repo deliberately has no `ARCHITECTURE.md`
(the layout is the architecture), skip this.

## 5. docs/adr/ *(or whatever this repo calls its decision log)*

- Did this thread make a decision that sets a new direction? If so it needs an ADR —
  check none was skipped.
- Never edit an Accepted ADR's Context/Decision. If a prior decision changed this
  thread, the fix is a **new** ADR that sets the old one's status to
  "Superseded by ADR-NNNN."
- Check for two ADRs contradicting each other on the same topic; resolve which is
  current.

## 6. Proposals *(only if the repo keeps a proposal tier)*

Wherever proposals live — `work/NNNN-slug/proposal.md`, a classic `docs/rfcs/`, or
somewhere else this repo chose: if a proposal discussed this thread reached a decision, note
that its rationale belongs in an ADR and its status should flip to
"Accepted → ADR-NNNN" (or Rejected) and out of active discussion.

## 7. work/NNNN-slug/ *(only if the repo tracks in-flight work in-repo)*

- If this thread's work merged or is done: distill anything durable first (decision
  rationale → ADR; reference knowledge → docs/ or a skill), then move the folder to
  `work/archive/`. Never propose deleting a work item, even one that looks like it
  holds nothing durable. A stale `spec.md` left active poisons future agent searches;
  an archived one is explicitly historical.
- If still in flight, make sure `plan.md`/`notes.md` reflect where you *actually* left
  off, not the original plan.
- **If it is neither active nor finished** — paused, waiting on something, held for a
  decision — check its premises still hold. Its status line says the pause is deliberate,
  which reads as "nothing to do here", so this is the one case a review skips by default.
  A held plan that references something *this thread deleted* is not paused any more; it
  is stale, and its own status is what hides that. Say so rather than leaving the label
  to speak for it.

## 8. Skills and agent-facing guides *(wherever this repo keeps them)*

`.claude/skills/` is this blueprint's default, not a requirement — a repo may keep agent
guides under `.agents/`, `docs/`, or a path only its index knows. **Locate them from the
root `AGENTS.md` index rather than a fixed path.** If no index resolves them, say so and
name the paths you checked; "could not locate" is the honest answer, and a quiet skip is
the bug this section exists to avoid.

For any skill or guide touched: if it carries frontmatter, confirm its `description`
still matches what it does — that description **is** the retrieval trigger, so a stale
one means the skill stops firing silently. If it carries none, check the same property
one level up: is its index entry still accurate, and does the guide still describe
reality?

**Did any skill mislead this thread?** If the thread deviated from a skill's
instructions — worked around a step, ignored a stale command, needed a skill that
didn't exist — and no report was filed at the time, file it now with
`/myconv:report-skill-feedback`. This is the safety net; the moment of deviation was
the right time.

## 9. CHANGELOG.md *(only if the repo keeps one)*

Add an entry if anything user-visible shipped.

## 10. The corrected-fact sweep

If this thread **corrected a fact that was written down** — a count, a version, a
filename, a mechanism, a command inventory — search for the old form before finishing. A
fact corrected in one file and left standing in three is worse than never correcting it:
the stale copies now disagree with a source that looks authoritative.

**Bound the sweep to documentation and instruction surfaces**: `*.md`, agent instruction
files, and hand-maintained config comments. Exclude vendored trees, lockfiles, test
fixtures and generated output, where the old string is usually still correct and a
version number would otherwise return the whole repo. **Cap the report**: a few hits per
fact, grouped by file, and a count of what you suppressed — not every match.

## 11. Traceability & write-back

- **Commits → decisions:** did commits made this thread reference the ADR/proposal they
  trace back to? Flag any direction-setting commit that doesn't.
- **Write-back loop:** was anything durable learned this thread (a gotcha, a convention,
  a procedure) that currently has no home? Propose where it should land, in this order:
  an **ADR** if it is a decision, the **architecture doc** if it is structure,
  **`AGENTS.md`** if it is a standing rule, a **skill** if it is a procedure.
- **A durable fact whose only home is a commit message is lost** — commit messages are
  not what future agents search. The same goes for a thread summary nobody will re-read.

## 12. Apply vs. propose

- **Dry-run overrides this section:** if invoked with `--dry-run` (see *Mode* above),
  apply nothing — propose everything, mechanical fixes included.
- **Apply directly** only the mechanical, non-direction-setting fixes: a stale index
  link, a missing/malformed `CLAUDE.md` stub, an out-of-date skill description, a
  CHANGELOG line for something already shipped.
- **Draft and flag — do not auto-write** anything direction-setting: new ADRs,
  supersessions, proposal status changes. Present these for review before committing.
- Never push without approval.

## 13. Flag anything ambiguous

Instead of guessing: unsure whether a decision needs an ADR, whether a `work/` folder is
really done, or how to word a skill trigger — list these separately for me.

---

**End with a short summary:** files changed by category (AGENTS/CLAUDE, ADR,
`work/` — proposals included — skills, CHANGELOG), what you applied vs. what you
drafted, and open items needing my review before I clear. **Repeat §0's tier map** with
what each tier yielded, every "not kept" and "could not locate" included — up front it
set expectations; here it is the evidence that stops a list of passes reading as full
coverage.
