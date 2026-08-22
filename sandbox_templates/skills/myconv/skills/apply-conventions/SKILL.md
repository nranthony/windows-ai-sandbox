---
name: apply-conventions
description: Set up or audit a repo against the agent-native conventions blueprint — AGENTS.md entry point, thin CLAUDE.md stub, ADRs, work items, skills. Applies the reference by hand with judgment; never a blind copy.
argument-hint: "[--audit] [path]"
---

# Apply the agent-native repo conventions

**If these instructions are wrong, stale, or a bad fit for this repo:** file it with
`/myconv:report-skill-feedback` at the moment you deviate, before working around it.

## Mode

Parse `$ARGUMENTS` before anything else — both arguments are optional and order does not
matter:

- **A path** (anything that is not a flag) is the **target repo**: run the whole procedure
  against that directory, and read its files rather than the current one's. With no path,
  the target is the repo you are already in. If the path does not exist or is not a repo,
  say so and stop — do not fall back to the current repo silently.
- **`--audit`** means **report only**: run steps 1–5, present the gap, and stop there.
  Write nothing, in the target repo or anywhere else.

Say which mode you are in — target repo and audit-or-apply — in your first message, so a
mistyped path surfaces before any file is touched.

This skill carries the blueprint with it. Two directories sit next to this file:

- `reference/agentic_native_repo_scaffold.md` — the full write-up: target layout, the
  lean-core-vs-opt-in tiers, the provenance chain, entrypoint wiring, and setup checklists.
- `templates/` — genericised starting-point files (`AGENTS.md`, `ARCHITECTURE.md`,
  `docs/adr/0000-template.md`, `work/README.md`, `.claude/settings.json`, and more).

**This is a reference, not a scaffolder.** A blind copy loop cannot know a repo's context;
the earlier automated version flattened substantive `CLAUDE.md` files, force-enabled CI, and
set wrong `CODEOWNERS`. You have the judgment the script lacked — read the desired shape,
then decide what this particular repo should get.

## Where the shared skills come from — never paste them

The shared procedures (`make-plan`, `wrap-up`, `clickup-pull`, `clickup-report`) are
**delivered by this plugin**, not by this skill. If you can read this file, they are already
available on this machine as `/myconv:<name>` — whether the plugin was installed from the
marketplace or seeded into a container's agent home. They are *never* copied into a
consumer repo: an unnamespaced twin in the target's `.claude/skills/` shadows the maintained
copy and drifts, which is exactly the failure plugin distribution exists to prevent
(decision record ADR-0007, `docs/adr/0007-plugin-distribution.md` in the conventions repo).

A repo's own `.claude/skills/` is still part of the blueprint — for skills **that repo
writes about itself**: its build, its deploy, its domain procedures. Placing those is in
scope; re-homing these four is not. If a target machine will not have the plugin, say so
and treat installing it as the fix, rather than pasting copies.

## Procedure

1. **Orient in the target repo first.** Existing `AGENTS.md` / `CLAUDE.md` / `README.md`,
   whether `docs/adr/` or `work/` already exist, whether the repo is solo or reviewed, whether
   CI exists, and what the repo's own conventions already look like. Do this before reading
   the blueprint, so you assess the blueprint against reality rather than the reverse.
   Resolve every relative path and named script an existing `AGENTS.md` cites — including
   inside managed sandbox-notice markers, which are verified read-only: a dead reference
   there is still a dead instruction. Report it (the fix belongs upstream, to the sandbox
   tool); never edit inside the markers.
2. **Read the blueprint** — `reference/agentic_native_repo_scaffold.md`, at minimum its layout
   and "Not everything at once — lean core vs. opt-in" sections.
3. **Choose the tier, and say why.** Default to the lean core: `AGENTS.md` + thin `CLAUDE.md` +
   `ARCHITECTURE.md` + `README.md` + `.claude/skills/` (for the repo's *own* procedures —
   see above; the shared ones arrive with the plugin) + gitignored `AGENTS.local.md` (the
   ignore rule ships in `templates/.gitignore`, alongside the `.cache/` rule — place that
   file, or fold its lines into the repo's existing one). Add
   `docs/adr/` and a light `.claude/settings.json` for most repos. Treat `CODEOWNERS`,
   `CONTRIBUTING.md`, PR template and CI as team-ceremony opt-ins, and `work/` as the heavier
   provenance tier. An empty `work/` no one uses is worse than not having it. Add
   `validation/` only where the repo already measures its own behaviour against a corpus and
   has (or wants) a gate reading the result — it is evidence, so it needs something measured
   to be evidence of. If the repo skips `work/`, drop `plansDirectory` from the settings
   template (and the matching `work/plans/` line from `.gitignore`) — it points at a
   directory that won't exist.
4. **Settle the tracker link — ask, don't assume.** A repo is *linked* when a committed
   pins file (`.myclickup.toml`) exists with its workspace ID filled in; see the
   blueprint's external-tracker bullet for the three states. Resolve it now rather than
   leaving a half-configured repo behind:
   - **No pins file** → ask whether this repo's work is tracked in ClickUp. If no, skip
     the file entirely and move on. `/myconv:clickup-pull` and `/myconv:clickup-report`
     stay inert without it, so nothing dead is left behind.
   - **Yes, or a file exists with an empty ID** → ask for the workspace ID and the scope
     (which Space/Folder/List this repo draws work from, or the whole workspace), then
     write them in. **Never invent or guess an ID** — a valid-but-wrong one resolves
     silently against someone else's board. If the human doesn't have it to hand, leave
     the ID empty and say the repo is declared-but-not-pinned.
   - Once the ID is set, **confirm the two ClickUp skills are actually reachable** —
     `/myconv:clickup-pull` and `/myconv:clickup-report` come from this plugin, so
     confirm the plugin is available on the machines that will run them rather than
     copying anything into the repo. They also carry a `myclickup` CLI dependency: note
     it if that CLI isn't on the target machine. The skills stop cleanly, but the human
     should know why.
5. **Present the plan before writing.** List what you would add, adapt, or leave alone, with
   the reasoning. Get agreement. With `--audit`, stop here and report the gap only.
6. **Apply by hand.** Adapt each template to this repo — real paths, real owner, the repo's
   existing voice. Never paste a template verbatim if the repo's own patterns differ; the
   repo wins.
7. **Wire the entrypoint.** Each `AGENTS.md` gets a thin `CLAUDE.md` beside it containing a
   heading and `@AGENTS.md` — nothing else.
8. **Review the diff** before committing, and commit locally with a clear message.

## Guardrails

- **Never overwrite a substantive `CLAUDE.md`.** If one exists and is not already a thin
  `@AGENTS.md` pointer, leave it or merge deliberately, after asking.
- **Don't add `CODEOWNERS` or CI unless the repo wants them**, with the correct owner. A wrong
  `CODEOWNERS` silently changes who must approve every PR.
- **Templates are examples.** If a template mentions a path, tool, or section this repo does
  not have, drop it rather than importing dead instructions.
- **Never paste a shared skill into the target repo**, and never write a `.myclickup.toml`
  just to make the ClickUp skills look useful. The pins file is opt-in; without a real
  tracker link it is exactly the dead instruction the rule above forbids.
- **Never place an empty `validation/` tree**, and never leave the `example-corpus/`
  placeholder behind. Its thresholds are set to values nothing can pass, precisely so an
  unreplaced template fails loudly — but a repo that measures nothing should not get the
  directory at all. If the repo already has a baseline file the gate reads, adopting the tier
  means splitting it: enforced thresholds into `expected.json`, the record into
  `measured.json`. That split is a judgement about what the gate should fail on, so raise it
  rather than deciding it silently.
- **Work on a clean tree**, and never push without approval.
- **No secrets, no personal paths, no machine-specific values** in anything you write.

## What "done" looks like

An agent landing cold in the repo can read `AGENTS.md` and find the rules, the map, and the
operating loop without guessing — and every claim in that index points at something that
actually exists.
