# ADR-0001: Adopt the provenance tiers — docs/adr/, docs/rfcs/, work/

- Status: Accepted
- Date: 2026-07-31
- Deciders: nranthony + agent

## Context

This repo adopted the *skills* half of the `agentic-conventions` scaffold (vendored
`make-plan` and `wrap-up` into `sandbox_templates/skills/`, commit `1151235`) without the
*provenance* half. Four consequences had accumulated:

1. **`make-plan` had nowhere to write.** Its §2 says: use `work/NNNN-slug/`; or the repo's
   own planning location; or, having neither, **ask — don't invent a top-level directory**.
   This repo had neither, so the skill could not complete on its first real use.
2. **Four undeclared planning locations existed instead.** `docs/incoming/` (five
   dependency-guardrail documents, ~130KB), two root-level `IN_TRANSIT_*` / `REPO-SCAN_*`
   files with hand-rolled status headers and unenforced self-declared exit rules,
   `docs/*-plan.md` for plans that had already landed, and `docs/_archive/` as the exit.
3. **`docs/incoming/` was unreachable.** Nothing under `docs/` is auto-loaded; it must be
   linked from `AGENTS.md` to be seen. `docs/incoming/` was referenced by no file in the
   repo — not `AGENTS.md`, not `docs/index.md`, not the `justfile`.
4. **Security decisions had no home.** `AGENTS.md` requires that changes to
   security-sensitive files state their security impact, but offers only the commit message
   as a venue. The dependency-guardrail work arrived with a §4 "what we deliberately do not
   build" section written, in its own words, "so the decision is on record rather than
   re-litigated later" — an ADR with no `docs/adr/` to live in.

The 2026-07-02 agent-native migration plan explicitly skipped this tier: *"In-flight work is
tracked in ClickUp, so `work/`, `docs/rfcs/`, `docs/design/` are skipped."* That was correct
when the only in-flight work was ClickUp-tracked feature work. It stopped being correct when
multi-session design work with unresolved decisions started landing in the tree.

## Decision

Adopt three tiers, matching upstream [ADR-0003](https://github.com/nranthony/agentic-conventions)
(plans live in `work/`) and ADR-0005 (proposals live in `docs/rfcs/`):

- **`docs/adr/NNNN-slug.md`** — decisions. Required for anything affecting the security
  boundary, persistent data, public contracts, core architecture, or cross-repo conventions.
  Append-only; superseded ADRs are marked, never deleted.
- **`docs/rfcs/`** — proposals under discussion, with the scaffold's status lifecycle
  (`Draft → In review → Accepted → ADR-NNNN | Rejected`). Durable: an RFC persists as a
  discussion record after resolution.
- **`work/NNNN-slug/`** — in-flight implementation artifacts (`spec.md` → `plan.md` →
  `notes.md`), **deleted or moved to `work/archive/` when the work merges.** Native
  plan-mode drafts land in `work/plans/`, gitignored, via `plansDirectory`.

`docs/incoming/` is **retained and narrowed** to its literal meaning: an inbox for raw,
unprocessed external input. Material graduates from it to `docs/rfcs/` when it becomes a
proposal this repo is actually weighing.

Each tier is populated on adoption — no empty ceremony directories, per the scaffold's own
rule that an unused `docs/rfcs/` is worse than none.

**Not adopted:** beads (`.beads/`) — task breakdowns stay as a section of `plan.md`, which
upstream ADR-0003 calls "a complete workflow, not a degraded one"; `docs/design/`;
`docs/runbooks/` (`.agents/skills/` already fills that slot); `CHANGELOG.md`.

## Consequences

- The root-level `IN_TRANSIT_*` / `REPO-SCAN_*` pattern is retired. Live work migrates to
  `work/`; completed work goes to `docs/_archive/`.
- `work/` inherits an exit rule, so the stale-plan trap is structurally closed rather than
  policed — the failure mode both root-level files demonstrated by sitting in place for
  weeks after their content went stale.
- `AGENTS.md` gains a "Where things live" index covering all three tiers, since none of them
  are auto-loaded.
- The five dependency-guardrail documents split by kind rather than by arrival: three RFCs
  plus the rules draft in `docs/rfcs/`, the repo-specific application plan in
  `work/0001-dependency-guardrails/` (completed and archived 2026-08-03 to
  `docs/_archive/dependency-guardrails-plan.md`, per the exit rule below — the
  tier split is the decision; the path is where it landed).
- RFC filenames keep their imported `NN-` prefixes. The documents refer to each other as
  "plan 01" / "plan 02" in dozens of places; renaming for tidiness would have invalidated
  prose across ~130KB to no functional gain.
- `.claude/settings.json` is created (previously only the gitignored
  `settings.local.json` existed) to carry `plansDirectory`.

## Alternatives considered

- **Adopt `docs/adr/` only.** Cheapest, and defensible — it is the tier with the most
  content waiting. Rejected because it leaves `make-plan` still unable to complete, which
  was the trigger.
- **Keep `docs/incoming/` as the single tier for everything.** Rejected: it conflates raw
  research, live proposals, and an executable plan under one name with one (absent)
  lifecycle. The 38KB application plan and a stashed Gemini research dump need opposite
  exit rules.
- **`docs/plans/` as a permanent home.** Rejected for the same reason upstream ADR-0003
  rejected it: a permanent location with no exit rule accumulates precisely the stale
  context `work/` exists to expire.
- **Defer until the dependency-guardrail work is approved.** Rejected — the restructure is
  what makes that plan reviewable, so deferring inverts the dependency.
