---
name: apply-conventions
description: Set up or audit a repo against the agent-native conventions blueprint — AGENTS.md entry point, thin CLAUDE.md stub, ADRs, work items, skills. Applies the reference by hand with judgment; never a blind copy.
argument-hint: "[--audit] [path]"
---

# Apply the agent-native repo conventions

This skill carries the blueprint with it. Two directories sit next to this file:

- `reference/agentic_native_repo_scaffold.md` — the full write-up: target layout, the
  lean-core-vs-opt-in tiers, the provenance chain, entrypoint wiring, and setup checklists.
- `templates/` — genericised starting-point files (`AGENTS.md`, `ARCHITECTURE.md`,
  `docs/adr/0000-template.md`, `work/README.md`, `.claude/settings.json`, and more).

**This is a reference, not a scaffolder.** A blind copy loop cannot know a repo's context;
the earlier automated version flattened substantive `CLAUDE.md` files, force-enabled CI, and
set wrong `CODEOWNERS`. You have the judgment the script lacked — read the desired shape,
then decide what this particular repo should get.

## Procedure

1. **Orient in the target repo first.** Existing `AGENTS.md` / `CLAUDE.md` / `README.md`,
   whether `docs/adr/` or `work/` already exist, whether the repo is solo or reviewed, whether
   CI exists, and what the repo's own conventions already look like. Do this before reading
   the blueprint, so you assess the blueprint against reality rather than the reverse.
2. **Read the blueprint** — `reference/agentic_native_repo_scaffold.md`, at minimum its layout
   and "Not everything at once — lean core vs. opt-in" sections.
3. **Choose the tier, and say why.** Default to the lean core: `AGENTS.md` + thin `CLAUDE.md` +
   `ARCHITECTURE.md` + `README.md` + `.claude/skills/` + gitignored `AGENTS.local.md`. Add
   `docs/adr/` and a light `.claude/settings.json` for most repos. Treat `CODEOWNERS`,
   `CONTRIBUTING.md`, PR template and CI as team-ceremony opt-ins, and `work/` as the heavier
   provenance tier. An empty `work/` no one uses is worse than not having it.
4. **Present the plan before writing.** List what you would add, adapt, or leave alone, with
   the reasoning. Get agreement. With `--audit`, stop here and report the gap only.
5. **Apply by hand.** Adapt each template to this repo — real paths, real owner, the repo's
   existing voice. Never paste a template verbatim if the repo's own patterns differ; the
   repo wins.
6. **Wire the entrypoint.** Each `AGENTS.md` gets a thin `CLAUDE.md` beside it containing a
   heading and `@AGENTS.md` — nothing else.
7. **Review the diff** before committing, and commit locally with a clear message.

## Guardrails

- **Never overwrite a substantive `CLAUDE.md`.** If one exists and is not already a thin
  `@AGENTS.md` pointer, leave it or merge deliberately, after asking.
- **Don't add `CODEOWNERS` or CI unless the repo wants them**, with the correct owner. A wrong
  `CODEOWNERS` silently changes who must approve every PR.
- **Templates are examples.** If a template mentions a path, tool, or section this repo does
  not have, drop it rather than importing dead instructions.
- **Work on a clean tree**, and never push without approval.
- **No secrets, no personal paths, no machine-specific values** in anything you write.

## What "done" looks like

An agent landing cold in the repo can read `AGENTS.md` and find the rules, the map, and the
operating loop without guessing — and every claim in that index points at something that
actually exists.
