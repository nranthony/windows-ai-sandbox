# ADR-0010 — One proposal home: close the `docs/rfcs/` tier

- **Status:** Accepted (2026-08-25)
- **Date:** 2026-08-25
- **Supersedes:** [ADR-0001](0001-provenance-tiers.md) **in part** — only its
  `docs/rfcs/` bullet. The `docs/adr/` and `work/` tiers ADR-0001 adopted stand
  unchanged. ADR-0001 stays as written (append-only); it carries a supersession
  note pointing here for the one bullet this ADR closes.
- **Affects:** `docs/rfcs/` (removed — contents moved to `docs/_archive/`),
  `AGENTS.md` ("Where things live"), `work/README.md` (exit rule, "What does
  not go here"), `docs/index.md`, `docs/incoming/README.md` (graduation rule),
  ARCHITECTURE.md (repo map).

## Context

`docs/rfcs/` held five files, all imported 2026-08-03/06, and nothing has been
added to it since. Every later proposal — work/0009, 0012, 0013, 0014 — went
straight into `work/NNNN-slug/spec.md` as a spec with a decision-gate section,
never through an RFC. The tier is dormant, not merely quiet.

Upstream `agentic-conventions` reached the same conclusion first. Its scaffold
blueprint
(`sandbox_templates/skills/myconv/skills/apply-conventions/reference/agentic_native_repo_scaffold.md`)
retired the separate RFC tier explicitly:

> There is deliberately **one** proposal home. A separate `docs/rfcs/` tier was
> tried and retired: two numbered pipelines meant every proposal needed a
> "which one?" decision, and the answer to "what's proposed?" and "what's in
> flight?" turned out to be the same folder.

It now has a proposal start inside `work/NNNN-slug/proposal.md`, carrying the
same `Draft | In review | Accepted → ADR-NNNN | Rejected` status header the
RFC template used, then growing `spec.md`/`plan.md`/`notes.md` if accepted.

[ADR-0001](0001-provenance-tiers.md) cited upstream's now-superseded ADR-0005
when it adopted the RFC tier locally, and stated its own rule against exactly
this outcome: "no empty ceremony directories, per the scaffold's own rule that
an unused `docs/rfcs/` is worse than none." Seven weeks unused is that rule
firing.

## Decision

1. **`docs/rfcs/` is closed.** No new RFCs. Files kept unrenumbered in
   `docs/_archive/` (not `work/proposal.md` — this repo already names its
   proposal file `spec.md`, and introducing a second name would recreate the
   "which one?" problem the blueprint describes).
2. **New proposals live in `work/NNNN-slug/spec.md`**, carrying a status line
   `Draft → Accepted → ADR-NNNN | Rejected`. This is the existing `work/` entry
   point, not a new file name.
3. **`work/`'s exit rule tightens to archived, not deleted.** A merged item's
   folder is archived to `docs/_archive/`; nothing exits by deletion. The one
   standing exception — work/0002, deleted in `151cebf` — is closed by
   restoring it to `docs/_archive/0002-host-side-skill-slot-plan.md`, so the
   rule has no exception left to point to.

## Consequences

- **One fewer decision per proposal.** An operator no longer chooses between
  an RFC and a work item before writing anything down; every proposal starts
  the same way.
- **RFC-05** (`--repo` filter for `profile.sh deps`, draft, unimplemented) is
  marked Rejected in place with a one-line note that it closed with the tier
  and can be revived as a `work/` item. Its content is otherwise untouched.
- **`docs/incoming/`'s graduation rule retargets to `work/`.** Material that
  becomes a proposal this repo is weighing now graduates straight to
  `work/NNNN-slug/spec.md`; there is no intermediate RFC stop.
- **The `work/` exit-rule tightening plus the 0002 restore together close a
  gap**: before this ADR, "archived, not deleted" was the stated intent but
  had one counter-example sitting in git history. After the restore, every
  exited `work/` item — 0001, 0002, 0004, 0006, 0007, 0008, 0010, 0011 — has a
  live path under `docs/_archive/`.
- Inbound links to the five RFC files (from `docs/adr/0002`, `docs/adr/0004`,
  `docs/dependency-guardrails-handoff.md`, `docs/incoming/README.md`, and the
  archived `work/0001` plan) were repointed to their new `docs/_archive/`
  paths so none 404.

## Alternatives considered

- **Keep the tier and start using it.** Rejected on the evidence: nobody has
  in seven weeks, across four proposals that all had a real decision to make.
- **A `work/archive/` directory.** Rejected — `work/README.md` already
  records that this was tried once, the directory was never created, and the
  first item to exit went straight to `docs/_archive/` instead. One archive
  location, not two.
- **Delete the RFCs outright.** Rejected — they are a discussion record
  (`01` partly built as `depaudit`, `02` rejected as a system but its
  vocabulary retained, `04` partially applied) and ADR-0001's own rule keeps
  archived narrative rather than erasing it.
