# {{PROJECT_NAME}}

<!--
  This is a STARTING POINT to adapt by hand, not a drop-in file. Apply the
  conventions to your repo's actual shape; skip or tailor anything that doesn't fit.
  - Replace {{PROJECT_NAME}} with the real name (no scaffolder does it for you).
  - The sibling CLAUDE.md must be a two-line "@AGENTS.md" stub, written by hand.
    NEVER overwrite a repo's existing substantive CLAUDE.md with that stub.
  - Lines below only reference the lean core (ARCHITECTURE, docs/adr/, skills).
    Opt-in pieces (work/, runbooks, CHANGELOG) live in the commented block —
    move a line out of the comment only when the repo actually adopts the piece.

  Optional: tooling (e.g. <your-sandbox-tool>) may inject a managed notice block
  here describing shell restrictions. Leave a BEGIN/END marker pair if you use it;
  do not hand-edit managed blocks.

  Optional: cite where these conventions came from, if that helps this repo's
  contributors — e.g. a "Conventions: <url>" line below. Skip it when an external
  link is noise here, or when the source repo isn't readable by everyone on this
  project: a dead link is worse than no link.
-->

A project following the agent-native repository blueprint.

## Start here
When you begin work, in this order:
1. Read this file and ARCHITECTURE.md for the system shape.
2. Check docs/adr/ for decisions that constrain the area you're touching.
3. Match existing patterns in the file you're editing over generic conventions.

## Where things live
- System map & boundaries → [ARCHITECTURE.md](ARCHITECTURE.md)
- Why decisions were made → [docs/adr/](docs/adr/)
- How-to procedures → [.claude/skills/](.claude/skills/) (invocable as /name; auto-triggered by description)
- Per-package specifics → that package's own AGENTS.md (nearest file wins)
<!-- Opt-in — move a line above only when the repo adopts the piece:
- Proposals & in-flight work → [work/](work/) (NNNN-slug/: proposal → spec → plan → notes;
  distill durable rationale to an ADR, then archive — see work/README.md)
- Operational runbooks (how-tos that aren't skills) → [docs/runbooks/](docs/runbooks/)
- What changed → [CHANGELOG.md](CHANGELOG.md)
-->

## How to move forward (the loop)
- Trivial change (typo, local fix): just do it.
- Non-trivial change: confirm it doesn't contradict an ADR; if it sets a new
  direction, write a short ADR first.
- After implementing: run the project's checks and reference the ADR in your
  commit message. If the repo keeps a CHANGELOG, add a line for anything
  user-visible; if you used a work/ folder, distill anything durable (ADR/docs),
  then move it under `work/archive/` so stale specs don't pollute future context —
  items are archived, never deleted.
- If you learned something durable (a gotcha, a convention), write it back —
  a new ADR, a skill, or a line here — so the next session doesn't re-derive it.

## Golden rules
- Never commit secrets; never hand-edit generated files (list them).
- Ask before adding a dependency or a new top-level package.
- Gloss before you cite: writing for a human, say what a thing is in plain
  language and put its code in parentheses after — "the no-scaffolder decision
  (ADR-0001)", not "per ADR-0001"; "the task-move item (R3)", not "R3".
  Covers project shorthand, not ordinary technical terms. Repeat mentions may
  drop the gloss.

## High-risk paths
List paths that require a written rationale, the verification step, and a
CODEOWNERS review before changing. See enforcement in .claude/settings.json
and .github/workflows/.

@AGENTS.local.md
