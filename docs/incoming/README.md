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

**Empty — last triaged 2026-08-03.** That is the intended steady state.

Where the previous three went, as a worked example of the exit rule: the two
post-incident checklists and the Gemini deep-research report all landed in
[`docs/_archive/`](../_archive/) (each with a one-line entry in
[`docs/index.md`](../index.md) saying what superseded it). Before archiving, the
two things in them that were **not** already covered were extracted — the
host-trust sections became
[RFC-04 §8](../rfcs/04-portable-guardrails-outside-sandbox.md), and the
shared-package-cache question became a watch item in
[the dependency-guardrails handoff](../dependency-guardrails-handoff.md) §6.

That is the pattern to repeat: **mine the delta first, then archive.** Archiving
without extracting loses the one paragraph that was worth the read.
