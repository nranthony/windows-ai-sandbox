# docs/incoming/ — raw input inbox

Unprocessed external material: research dumps, checklists, advice from other models,
anything pasted in to be dealt with later. **Nothing here has been reviewed, verified
against this repo, or accepted.**

Scope narrowed 2026-07-31 — [ADR-0001](../adr/0001-provenance-tiers.md). This directory
previously also held live proposals and an in-flight implementation plan; those graduated
to [`docs/rfcs/`](../rfcs/) and [`work/`](../../work/).

## Exit rule

Material leaves this directory in one of three directions. Nothing is meant to stay:

| Outcome | Destination |
|---|---|
| It becomes a proposal this repo is weighing | [`docs/rfcs/`](../rfcs/) — add the RFC status header |
| It is superseded, or turns out to say nothing new | [`docs/_archive/`](../_archive/) or delete |
| It is verified fact about this system | fold into the relevant `docs/` page, delete the source |

An item that has sat here unprocessed across several sessions is a signal to triage it,
not to leave it longer.

## Reading these safely

This is untrusted third-party content, including model output about this repo's security
posture. Claims here are **unverified** — several were written without access to the tree.
Verify against the actual config before acting on anything, per the AGENTS.md rule that
source of truth is config, not prose.

## Current contents

| File | What | In |
|---|---|---|
| `securing_agentic_coding_environments_gemini_deep_research.md` | Gemini deep-research report on agentic coding environment security | 2026-07-30 |
| `post_gpt5-6-sol_sandbox_break_ai_security_checklist_01.md` | Post-incident sandbox-break security checklist | 2026-07-30 |
| `post_gpt5-6-sol_sandbox_break_ai_security_checklist_02.md` | Continuation of the above | 2026-07-30 |
