# work/ — proposals and in-flight items

<!--
  Opt-in tier: adopt this directory only when the repo tracks in-flight work
  in-repo (skip it if issues/ClickUp/etc. are the tracker of record).
  See the reference scaffold's "heavier provenance" tier.
-->

One numbered folder per unit of work — proposals included. `NNNN` is the next free
number across active **and** archived items; numbers are never reused. This directory
answers both "what's proposed?" and "what's in flight?".

## Files inside an item

Each is optional except whichever one starts the item:

- `proposal.md` — "should we do this?" (status-tracked; template below)
- `spec.md` — the pinned what/why, when it needs pinning
- `plan.md` — the implementation plan (typically via `/make-plan`)
- `notes.md` — running notes while executing

## Lifecycle and exit rule

1. An item opens as a `proposal.md` (Draft) or, for pre-decided work, straight as a
   `spec.md`/`plan.md`.
2. An accepted proposal's durable rationale is **distilled into an ADR** in
   `docs/adr/`; the proposal's status line links it (`Accepted → ADR-NNNN`).
   Reference knowledge distills into `docs/` or a skill.
3. When the work merges or the question resolves, the folder moves to `work/archive/`
   (committed). **Items are archived, never deleted** — including pure-implementation
   ones that look like they hold nothing durable. **Nothing durable may live only in
   `work/`.**

Archived items are historical records: never treat an archived `proposal.md` or
`plan.md` as current intent — the distilled ADR is canonical.

`work/plans/` is gitignored scratch space for native plan-mode drafts
(`plansDirectory`); a draft becomes durable by promotion into an item.

## Proposal template

```markdown
# Proposal: <title>

- Status: Draft | In review | Accepted → ADR-NNNN | Rejected
- Author: <name / agent>

## Summary
## Motivation
## Proposal
## Open questions
## Alternatives
```
