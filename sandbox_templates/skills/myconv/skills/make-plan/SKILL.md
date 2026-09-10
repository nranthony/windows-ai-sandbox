---
name: make-plan
description: Investigate the repo and produce a decision-ready implementation plan in work/NNNN-slug/ — planning only, no production edits. For changes big enough that the plan must outlive the session.
argument-hint: <feature, problem, or desired outcome>
---

# Make a plan

Produce a reviewable implementation plan for: $ARGUMENTS

**Planning only.** Do not modify production code, schemas, dependencies, CI, or anything
externally visible. The only files you may create are the plan artifacts and draft ADRs
named below.

**If these instructions are wrong, stale, or a bad fit for this repo:** file it with
`/myconv:report-skill-feedback` at the moment you deviate, before working around it. If
that command isn't available here, write the report into your own repo — the open work
item, or `feedback/sent/` — and name delivery as a human-ferried step.

## Ground rules

- Repo evidence over assumption. Never claim a file, API, or convention exists without
  verifying it in the tree or git history.
- If sources conflict (AGENTS.md vs code vs an ADR), record the conflict — don't
  silently pick a side.
- **Where this repo publishes its own shape, that wins.** Its `AGENTS.md`, its
  `work/README.md` lifecycle, its ADRs and its existing plans are the authority; the
  defaults below apply where it publishes nothing, and where you take one, name it as a
  default rather than as the rule.
- **A repo's rules about tracked-file content beat any instruction here to write it.**
  Where the repo restricts what may enter committed files, quote less: restate rather
  than paste, keep pointers (IDs, paths, URLs) that leak nothing, and say in the plan
  what you left out and why. De-identification is labelled, never silent.
- Ask clarifying questions only when the answer materially changes scope, architecture,
  security, persistent data, public contracts, or acceptance criteria. Otherwise
  investigate first. Even then, prefer writing the plan with bounded alternatives and an
  explicit decision request; stop without producing artifacts only if the unanswered
  question means there is no coherent work item to plan yet.
- Label claims that affect scope, design, risk, or sequencing as **Confirmed** (verified
  in repo/task), **Inferred** (plausible — say what would validate it), or
  **Needs-decision** (human must choose). Don't tag ordinary connective prose.

## 1. Orient

Read, in order: the root `AGENTS.md` (and any nested one covering the affected area);
`ARCHITECTURE.md` if the repo keeps one; ADRs that constrain this area; `work/` for
overlapping in-flight items; then the relevant implementation, tests, and recent git
history. Fan wide investigation out to Explore subagents where they are available;
otherwise run focused searches across the candidate subtrees rather than serially
reading everything. Summarize only the facts that shape the plan.

**An empty search has two outcomes, not one.** *Absent* — the repo doesn't keep that
tier, which is usually a deliberate choice and not a gap — and *could not locate*, where
it may be kept under a name you don't know. Before recording either, check the repo's own
`AGENTS.md` for where it says things live. Where a search still comes up empty and the
answer shapes the plan, name the paths you checked in the plan's evidence section; a step
you skipped must never read as one that passed.

Record the branch and short SHA you investigated at, so a later session can tell whether
the tree moved: in the item's front-matter block if the repo keeps one
(`- Investigated-at: <branch> <shortsha> — <date>`, placed as that repo places its other
front-matter keys), otherwise directly under the plan's title.

## 2. Where the plan lives

- If the repo keeps `work/`: create `work/NNNN-slug/` with `plan.md`, plus `spec.md`
  first if the "what/why" needed pinning down. Take the highest number across active
  **and** archived items and add one, matching the zero-padding already in use — numbers
  are never reused, so a scan that misses `work/archive/` can hand back one that is
  taken. If the repo's own `work/README.md` states a different numbering rule, that wins.
  If the work traces to an existing item (e.g. an accepted `proposal.md`), put `plan.md`
  in that folder instead of opening a new number. The exit rule applies: when the work
  merges, durable rationale is distilled out (ADR/docs) and the folder moves to
  `work/archive/` — items are archived, never deleted.
- If the repo has its own planning location, use that; §4 puts draft decision records
  through the same fallback, so the two read as one rule. If it has neither, ask where
  the plan should live — don't invent a new top-level directory.
- If the repo uses beads (`.beads/` present): file the task breakdown as a bd epic with
  dependent tasks, link the epic ID from `plan.md`, and do **not** leave a parallel
  markdown checklist. Milestone sequencing and dependency shape still belong in the plan;
  it is the leaf tasks that live in bd. Otherwise, include the task breakdown as a section
  of `plan.md` — that is the complete workflow, not a degraded one. Never install beads or
  suggest adopting it; whether a repo uses bd is a per-repo decision already made elsewhere.

## 3. plan.md contents

Problem and intended outcome · verified evidence and constraints · scope and explicit
non-goals · assumptions and open questions (classified) · proposed design and
alternatives considered · ordered file-level implementation steps · data/API/config
compatibility and migration effects · security, reliability, and rollback
considerations · validation plan (the actual commands) · acceptance criteria ·
risks and sequencing · task breakdown (or the bd epic link).

Cover all of them. Use them as the section headings, in this order, unless the repo has
its own plan template or an existing plan worth matching — then follow that. The order is
a default, and its value is that two plans can be read against each other.

Validation commands must come from repo scripts, CI config, developer docs, or existing
test conventions — copy them, don't guess. If no applicable command is verified, say so
and make command selection a Needs-decision rather than inventing a plausible one.

Be specific enough that a separate session can execute one task without rediscovering
the architecture. State "none identified" only after actually looking.

## 4. Consequential decisions → draft a decision record

If a choice affects public contracts, persistent data, security boundaries, core
architecture, or cross-repo conventions, its rationale belongs in the repo's decision
record rather than buried in the plan. Which record that is depends on what the repo
keeps — the same ladder as §2, and you never invent a directory:

- **`docs/adr/`** — draft a `Proposed` ADR there, in the repo's own template and numbering.
- **A decision log kept elsewhere or in another shape** — a `DECISIONS.md`, a numbered
  table, a log beside the plans. Draft the entry **in that repo's format**, as a proposed
  row or a file next to the plan, and say in the plan where it lands once accepted. Do
  not create `docs/adr/` alongside it.
- **No decision record at all** — record the decision in `plan.md` under its own heading,
  say plainly that it has no durable home yet, and ask where such records should live.

Never rewrite an accepted record where the repo holds its log append-only — supersede
instead — and don't hand-edit a generated ADR index. Local implementation details never
get a decision record.

## 5. Approval gate — always stop here

Do not implement. End with: the plan path · a one-paragraph recommendation · key
verified findings · the decisions needing approval (only those) · blocking questions,
if any · the suggested first task once approved.
