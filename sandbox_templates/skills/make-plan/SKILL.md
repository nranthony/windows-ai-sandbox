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

## Ground rules

- Repo evidence over assumption. Never claim a file, API, or convention exists without
  verifying it in the tree or git history.
- If sources conflict (AGENTS.md vs code vs an ADR), record the conflict — don't
  silently pick a side.
- Ask clarifying questions only when the answer materially changes scope, architecture,
  security, persistent data, public contracts, or acceptance criteria. Otherwise
  investigate first.
- Label every significant statement: **Confirmed** (verified in repo/task),
  **Inferred** (plausible, needs validation), or **Needs-decision** (human must choose).

## 1. Orient

Read, in order: the root `AGENTS.md` (and any nested one covering the affected area);
`ARCHITECTURE.md` if the repo keeps one; ADRs that constrain this area; `work/` for
overlapping in-flight items; then the relevant implementation, tests, and recent git
history. Fan wide investigation out to Explore subagents rather than serially reading
everything yourself. Summarize only the facts that shape the plan.

## 2. Where the plan lives

- If the repo keeps `work/`: create `work/NNNN-slug/` (next free number) with `plan.md`,
  plus `spec.md` first if the "what/why" needed pinning down. The exit rule applies:
  this folder is deleted or archived when the work merges.
- If the repo has its own planning location, use that. If it has neither, ask where the
  plan should live — don't invent a new top-level directory.
- If the repo uses beads (`.beads/` present): file the task breakdown as a bd epic with
  dependent tasks, link the epic ID from `plan.md`, and do **not** leave a parallel
  markdown checklist. Otherwise, include the task breakdown as a section of `plan.md` —
  that is the complete workflow, not a degraded one. Never install beads or suggest
  adopting it; whether a repo uses bd is a per-repo decision already made elsewhere.

## 3. plan.md contents

Problem and intended outcome · verified evidence and constraints · scope and explicit
non-goals · assumptions and open questions (classified) · proposed design and
alternatives considered · ordered file-level implementation steps · data/API/config
compatibility and migration effects · security, reliability, and rollback
considerations · validation plan (the actual commands) · acceptance criteria ·
risks and sequencing · task breakdown (or the bd epic link).

Be specific enough that a separate session can execute one task without rediscovering
the architecture. State "none identified" only after actually looking.

## 4. Consequential decisions → draft ADRs

If a choice affects public contracts, persistent data, security boundaries, core
architecture, or cross-repo conventions, draft a `Proposed` ADR in `docs/adr/` (repo's
template and numbering) instead of burying the rationale in the plan. Local
implementation details never get ADRs.

## 5. Approval gate — always stop here

Do not implement. End with: the plan path · a one-paragraph recommendation · key
verified findings · the decisions needing approval (only those) · blocking questions,
if any · the suggested first task once approved.
