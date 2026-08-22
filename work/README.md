# work/ — in-flight implementation artifacts

Design-layer plans for work that is **currently in flight**. One folder per work item,
`NNNN-slug/`, holding `spec.md` (what/why, when it needed pinning down) → `plan.md`
(design + ordered steps) → `notes.md` (execution log).

Adopted 2026-07-31 — [ADR-0001](../docs/adr/0001-provenance-tiers.md).

## The exit rule — this is the point of the directory

**When a work item's changes merge, delete its folder or move it to
[`docs/_archive/`](../docs/_archive/)** — the same destination the table below
gives for completed work. (This used to say `work/archive/`, a directory that was
never created; the first item to exit went to `docs/_archive/`.)

A stale `plan.md` left in the tree quietly poisons future agent context: it reads as
current intent long after it stopped being true. The two root-level `IN_TRANSIT_*` /
`REPO-SCAN_*` files this tier replaced are the worked example — both carried a
hand-written "delete this when done" note, and both were still sitting at the repo root
weeks after their content went stale.

## What does *not* go here

| Kind | Home |
|---|---|
| Proposal under discussion | [`docs/rfcs/`](../docs/rfcs/) — durable, survives resolution |
| A decision and its rationale | [`docs/adr/`](../docs/adr/) — append-only |
| Raw unprocessed external input | [`docs/incoming/`](../docs/incoming/) |
| How-to procedure | [`.agents/skills/`](../.agents/skills/) |
| Completed work worth keeping | [`docs/_archive/`](../docs/_archive/) |

## Current items

| # | Item | Status |
|---|---|---|
| [0002](0002-host-side-skill-slot/plan.md) | Host-side skill slot (`make-plan` is container-only) | Not started |
| [0003](0003-repo-scan-audit/plan.md) | Repo scan — audit + housekeeping | Planning, execution mode not chosen |
| [0004](0004-deletion-is-a-human-step/plan.md) | Deletion is a human step — hook blocks bulk shapes, not the verb | Not started, parked |
| [0006](0006-manifest-keys-the-consumer-drops/plan.md) | Manifest keys the channel consumer silently drops | Not started, **re-investigate first** |
| [0007](0007-genericise-public-identifiers/spec.md) | Genericise profile/client identifiers in a public repo | Not started, **scope decision first** |
| [0008](0008-the-python-half-of-the-gates/plan.md) | The Python half of the dependency gates (Gate 3 project overrides, uv age gate, `uv audit`) | Not started, **verify §2.3 before implementing** |
| [0009](0009-the-third-cli-runs-on-bun/spec.md) | opencode as the third in-container CLI (OpenRouter provider) — its runtime is Bun, so Gate 2 and the proxy env do not carry over | **Parked** — specified, not scheduled; **Phase 0 measurement first** on unparking |

Exited: **0001 dependency guardrails** — complete (T00–T26), archived 2026-08-03
to [`docs/_archive/dependency-guardrails-plan.md`](../docs/_archive/dependency-guardrails-plan.md);
the live record is
[`docs/dependency-guardrails-handoff.md`](../docs/dependency-guardrails-handoff.md).

Exited: **0005 cross-repo skill pipeline** — work landed 2026-08-13, §5 closed by
myclickup's reply, archived 2026-08-18 to
[`docs/_archive/cross-repo-skill-pipeline-notes.md`](../docs/_archive/cross-repo-skill-pipeline-notes.md).
Its durable rule — *the detector belongs on the side that owns the stale copy, and
a skip is not a pass* — is maintained in [`AGENTS.md`](../AGENTS.md) under
"Boundary monitors".

## plans/

`work/plans/` is gitignored and holds Claude Code's native plan-mode drafts
(`plansDirectory` in `.claude/settings.json`). Drafts are **not** the durable artifact — a
draft becomes durable by being promoted to a `work/NNNN-slug/plan.md`.
