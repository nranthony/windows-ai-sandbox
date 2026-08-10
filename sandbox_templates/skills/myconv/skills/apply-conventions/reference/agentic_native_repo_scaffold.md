# Agent-Native Repo Scaffold (generic)

A portable starting layout for any repository, on any system or container, that you want agents to operate in well. This intentionally ignores language, build, and runtime specifics (those belong in per-package files) and focuses on the **administrative layer**: instructions, provenance, decisions, documentation, and the bookkeeping that lets an agent orient itself and know how to move forward.

Two ideas carry the whole thing:

1. **One entry point.** `AGENTS.md` is the source of truth and the *index*. An agent reads it first, and from it learns where everything else lives.
2. **A durable paper trail.** Every "why," "what changed," and "how we do X" has one obvious home that's committed to the repo — not held in an agent's ephemeral session memory.

---

## The layout

```
.
├── AGENTS.md                  # ENTRY POINT: rules + index/map + operating procedure
├── CLAUDE.md                  # generated thin file: "@AGENTS.md"  (Claude Code reads this)
├── ARCHITECTURE.md            # the mental map: lean diagram + boundaries
├── README.md                  # human onboarding (install/run). NOT the agent's file.
├── CHANGELOG.md               # provenance of notable changes over time
├── CONTRIBUTING.md            # how a change gets proposed → reviewed → merged
├── CODEOWNERS                 # which paths require which reviewers (enforcement)
├── AGENTS.local.md            # gitignored personal context, imported by AGENTS.md if present
│
├── .claude/
│   ├── settings.json          # committed: permissions + hooks (the enforcement layer)
│   ├── settings.local.json    # gitignored personal overrides
│   ├── skills/                # reusable procedures, auto-discoverable + /name invocable
│   │   └── <skill-name>/
│   │       └── SKILL.md       #   folder + SKILL.md with name/description frontmatter
│   └── rules/*.md             # high-precedence hard rules (use sparingly)
│
├── .github/
│   ├── pull_request_template.md
│   └── workflows/             # CI: lint, test, and the gate checks that enforce the rules
│
├── docs/
│   ├── adr/                   # DECISION PROVENANCE: numbered, append-only records
│   │   ├── 0000-template.md
│   │   └── 0001-record-architecture-decisions.md
│   ├── design/                # durable design references
│   └── runbooks/             # operational how-tos that aren't skills
│
└── work/                      # ACTIVE-WORK PROVENANCE (optional): proposals + the in-flight trail
    ├── README.md              #   the item lifecycle + proposal template
    ├── NNNN-slug/             #   proposal.md → spec.md → plan.md → notes.md
    ├── archive/               #   closed items, distilled first (durable "why" → docs/adr/)
    └── plans/                 #   gitignored: native plan-mode drafts (via plansDirectory)
```

Per-language / per-package directories (each with its own `AGENTS.md` + generated `CLAUDE.md`) hang off this as needed; they hold the build/test/env specifics and are deliberately out of scope here.

---

## Not everything at once — lean core vs. opt-in

This is the full menu, not a mandatory checklist. Most repos want the lean core and
add the rest only when a concrete need appears. Adopt in this order:

- **Core (every repo):** `AGENTS.md`, the thin `CLAUDE.md`, `ARCHITECTURE.md`,
  `README.md`, `.claude/skills/`, and gitignored `AGENTS.local.md`. This alone makes a
  repo agent-native.
- **Keep-ish (most repos):** `docs/adr/` for the durable "why", and a light
  `.claude/settings.json`.
- **Opt-in — team ceremony (add when others review/merge):** `CODEOWNERS`,
  `CONTRIBUTING.md`, the PR template, CI gate checks. Solo, these are overhead — and
  `CODEOWNERS` with the wrong owner actively changes approval requirements, so don't add
  it reflexively.
- **Opt-in — sandboxed execution (add only if agents edit this repo inside a restricted
  sandbox):** a machine-managed environment notice at the top of `AGENTS.md` — see
  "Environment notice" below.
- **Opt-in — heavier provenance (add for long-lived or high-autonomy repos):**
  `docs/design/` and `work/` — one numbered folder per unit of in-flight work,
  **proposals included**: an item starts as `work/NNNN-slug/proposal.md`
  (`Draft | In review | Accepted → ADR-NNNN | Rejected`) and grows
  `spec.md`/`plan.md`/`notes.md` in the same folder if accepted. If in-flight work is
  tracked outside the repo (issues, ClickUp, etc.), skip `work/` entirely. `work/`
  carries an exit rule: **when the work merges or the question resolves, distill
  anything durable out (decision rationale → an ADR; reference knowledge → docs/ or a
  skill), then move the folder under `work/archive/`** — or delete it if nothing
  durable remains. A stale `spec.md` left active quietly poisons future agent searches
  and context; an archived one is explicitly historical.
  Pair it with `"plansDirectory": "./work/plans"` in `.claude/settings.json` (and
  gitignore `work/plans/`) so Claude Code's native plan-mode drafts land beside the
  durable plans instead of evaporating in `~/.claude/plans/`; a draft becomes durable by
  being promoted to `work/NNNN-slug/plan.md`. Repos that skip `work/` should drop the
  `plansDirectory` line when adapting the settings template. The `work/` slot stays
  tool-neutral — plans are plain markdown any agent runtime can consume.
  *(Team-scale alternative: repos where collaborators genuinely discuss proposals
  asynchronously in-file can keep a classic `docs/rfcs/` as the proposal home instead —
  same status header, proposals persisting in place after resolution.)*

Rule of thumb: start at the core and let real need pull each further piece in. An empty
`work/` no one uses is worse than not having it.

---

## The provenance chain — which file answers which question

This is the core of "how agents know where to look." Each question has exactly one home, so neither an agent nor a human has to guess.

| The question | Lives in | Shape |
|---|---|---|
| What are the rules, and where is everything? | `AGENTS.md` | Short, indexed, links out |
| What does the system look like? | `ARCHITECTURE.md` | One diagram + boundaries |
| **Why** does this exist / why this way? | `docs/adr/` | Numbered, append-only, status-tracked |
| What change is being *proposed*? | `work/NNNN-slug/proposal.md` | Status-tracked; distilled into an ADR on acceptance |
| What changed, and when? | `CHANGELOG.md` + commit messages | Reverse-chronological |
| How do I *do* a recurring task? | `.claude/skills/<name>/SKILL.md` | Self-contained; `/name` + auto-trigger |
| Operational how-to (not a skill) | `docs/runbooks/` | Step-by-step |
| Who must approve changes here? | `CODEOWNERS` | Path → reviewer |
| What's in flight right now? | `work/NNNN-slug/` | spec → plan → notes |
| How does a change get merged? | `CONTRIBUTING.md` | Process |

The lifecycle reads left to right, mostly inside one numbered folder: a **proposal** (`work/NNNN-slug/proposal.md`) proposes → an **ADR** records the decision → the same item's **plan.md/notes.md** track the implementation → the **CHANGELOG** and commit (referencing the ADR) record the outcome, and the item archives. That chain is the provenance: any line of code can be traced back to the decision and the reasoning that produced it.

---

## Discoverability: what's actually auto-loaded (and what isn't)

Design around this, because it's the difference between an elegant tree and an inert one.

- **`AGENTS.md` (root and nested)** is auto-loaded. Cursor and Gemini/Antigravity read it natively; Claude Code reads it through the generated `CLAUDE.md` that imports it (`@AGENTS.md`). **Nearest file wins**, so keep the root lean and push specifics down.
- **Skills** (`.claude/skills/<name>/SKILL.md`) are the *one* offload mechanism for procedures: auto-discovered, invocable by the human as `/name` (with `$ARGUMENTS` / `argument-hint`), *and* auto-triggerable by the agent when the `description` matches. Each `SKILL.md` needs YAML frontmatter with a `name` and a sharp `description` — that description *is* the trigger the agent matches against, so write it for retrieval, not prose, and make it say *when* the skill applies so heavyweight ones don't misfire. For a procedure that must only ever run when a human asks, set `disable-model-invocation: true` in its frontmatter. (Claude Code does **not** read the `.agents/skills/` cross-tool location some other runtimes propose — use `.claude/skills/`; revisit if that changes.)
- **Everything under `docs/`, `ARCHITECTURE.md`, `work/`** is **not** auto-loaded. It's only seen if `AGENTS.md` links to it *and* the workflow tells the agent when to read it. That's fine — it keeps context lean — but it means `AGENTS.md` must act as an index, and the links must be **relative** (`[docs/adr/](docs/adr/)`), never absolute `file://` paths, so they stay portable across checkouts, zips, and containers.

- **Slash commands (`.claude/commands/*.md`) → migrate to skills.** Claude Code merged commands into skills: a skill creates the same `/name` invocation with the same frontmatter, plus supporting files and invocation control. Commands still work and aren't deprecated, but keep **one** slot — move each `commands/foo.md` to `skills/foo/SKILL.md` (add `name:` frontmatter; on a name collision the skill wins). The old fork "auto-invoke → skill; human-invoke → command" is now the per-skill `disable-model-invocation` flag. See [ADR-0004](../docs/adr/0004-skills-replace-slash-commands.md).

So the rule of thumb: **rules and the index** go in `AGENTS.md`; **procedures** — whether the agent reaches for them or a human invokes them — become skills; **everything else** is referenced on demand.

---

## Entrypoint wiring (portable, no symlinks)

Generate thin per-tool entrypoints instead of symlinking — symlinks break on some Windows checkouts, IDE agent sandboxes, and zip exports. `CLAUDE.md` at every level that has an `AGENTS.md` is just:

```markdown
# CLAUDE.md
@AGENTS.md
```

Write these by hand — there are only ever a handful, one per directory that has an
`AGENTS.md`. **Deliberately no sync script.** An automated regenerator that walks the
tree and writes `CLAUDE.md` next to every `AGENTS.md` will happily flatten a
*substantive* hand-written `CLAUDE.md` into the two-line stub — a real footgun. When you
add a new package with its own `AGENTS.md`, add the two-line `CLAUDE.md` beside it in the
same commit. If you ever want a check, prefer a read-only CI assertion that *fails* when a
`CLAUDE.md` is missing or malformed over anything that *writes* files.

(`GEMINI.md` is no longer needed — the standalone Gemini CLI is retired and Antigravity reads `AGENTS.md` natively.)

---

## Advice vs. enforcement

`AGENTS.md` tells a cooperative agent what to do; it does not *stop* anything. For rules that actually matter, back the prose with mechanisms that don't depend on the agent reading them:

- **`.claude/settings.json`** — permission rules that set sensitive paths to `ask`/`deny`, and `PreToolUse` hooks that block edits to protected files. Commit this so it's shared.
- **`CODEOWNERS` + branch protection** — force human review on high-risk paths.
- **CI gate checks** — run the required verification whenever a protected path changes.
- **Sandbox deny-lists** — when agents run inside a restricted sandbox, pair the
  enforcement with an environment notice in `AGENTS.md` (next section).

State the intent in `AGENTS.md` ("why"); enforce it in hooks/CI ("can't"). Don't conflate "the agent was told" with "the control exists."

---

## Environment notice (opt-in: sandboxed repos)

When agents edit a repo from inside a restricted sandbox (denied network, blocked
installs, no remote git, …), the sandbox's deny-list is the enforcement — but an agent
that only discovers a restriction by hitting permission-denied will waste turns
retrying, hunting for bypasses, or silently giving up. The fix is an **environment
notice**: a block at the **very top** of the root `AGENTS.md`, before anything else,
because it changes what every instruction below it means.

This is the "advice" half of the previous section's advice-vs-enforcement split: the
sandbox blocks the action; the notice tells the agent *not to fight the block*.

Shape:

```markdown
<!-- BEGIN sandbox-notice (managed by <sandbox-tool> — do not edit here) -->
## ⚠️ This repo may be edited by an agent inside `<sandbox-tool>`

The agent's shell is restricted. The following **fail with permission-denied** —
do not attempt them, retry them, or hunt for a workaround; treat them as a human step:

- **No <capability>.** <denied commands>. <what to do instead — usually "stop and
  ask the human">.
- …

**What works:** <the allowed toolset, stated positively>.
<!-- END sandbox-notice -->
```

Three content rules make the notice effective; the exact denied-command list matters
less than these:

1. **State what fails, framed as "don't retry."** Name the denied commands so the
   agent recognizes the denial as policy, not a transient error — and doesn't reach
   for `bash -c` / `python -c` style workarounds (which a good sandbox also denies).
2. **Reframe every denial as a human step.** "If a package is missing, stop and ask
   the human to install it" turns a dead end into a plan the agent can hand back.
3. **State what works.** Without an explicit allow-side ("read/edit files, local git,
   run tests, `rg`/`jq`…"), agents over-avoid and start treating permitted actions as
   risky too.

Ownership rules:

- **The sandbox tool owns the block.** The `BEGIN/END … (managed by <tool>)` markers
  mean the tool regenerates it when the sandbox config changes; humans and agents
  never edit inside the markers. This is why the block's *content* is deliberately
  not templated in this repo — a copied deny-list drifts from the real sandbox config
  the first time the sandbox is tweaked, and a stale notice is worse than none.
- **The notice is per-repo, per-environment.** Repos not edited in a sandbox get no
  block at all; don't add an empty or speculative one.
- If the sandbox has no managing tool (a hand-maintained setup), the block can be
  hand-written — keep the markers anyway, name the config it mirrors, and update it
  in the same commit as any sandbox-config change.

---

## Starter templates

### `AGENTS.md` (the centerpiece — index + procedure)

```markdown
# <Project Name>

<One sentence: what this repo is.>

## Start here
When you begin work, in this order:
1. Read this file and ARCHITECTURE.md for the system shape.
2. Check docs/adr/ for decisions that constrain the area you're touching.
3. Check work/ for anything already in flight on this.
4. Match existing patterns in the file you're editing over generic conventions.

## Where things live
- System map & boundaries → [ARCHITECTURE.md](ARCHITECTURE.md)
- Why decisions were made → [docs/adr/](docs/adr/)
- Proposals & in-flight work → [work/](work/) (NNNN-slug/: proposal → spec → plan → notes)
- How-to procedures → [.claude/skills/](.claude/skills/) and [docs/runbooks/](docs/runbooks/)
- What changed → [CHANGELOG.md](CHANGELOG.md)
- Per-package specifics → that package's own AGENTS.md (nearest file wins)

## How to move forward (the loop)
- Trivial change (typo, local fix): just do it, then update CHANGELOG if user-visible.
- Non-trivial change: confirm it doesn't contradict an ADR; if it sets a new
  direction, write a short ADR (or a work-item proposal.md first if it needs discussion).
- After implementing: run the project's checks, reference the ADR/proposal in your
  commit message, and update CHANGELOG. If you used a work/ folder, distill anything
  durable (ADR/docs), then archive or delete it so stale specs don't pollute future
  context.
- If you learned something durable (a gotcha, a convention), write it back —
  a new ADR, a skill, or a line here — so the next session doesn't re-derive it.

## Golden rules
- Never commit secrets; never hand-edit generated files (list them).
- Ask before adding a dependency or a new top-level package.
- <Repo-wide invariants the agent must respect.>

## High-risk paths
Changes to <list paths> require: a written rationale in the commit, the
verification step <cmd>, and a CODEOWNERS review. See enforcement in
.claude/settings.json and .github/workflows/.

@AGENTS.local.md
```

### `docs/adr/0000-template.md`

```markdown
# ADR-NNNN: <short decision title>

- Status: Proposed | Accepted | Superseded by ADR-XXXX
- Date: YYYY-MM-DD
- Deciders: <people / agent + reviewer>

## Context
<The forces at play, constraints, what problem prompted this.>

## Decision
<What we decided to do.>

## Consequences
<Trade-offs accepted, what becomes easier/harder, follow-ups.>

## Alternatives considered
<Options rejected and why.>
```

ADRs are **append-only**: never rewrite an accepted one — supersede it with a new record and flip the old one's status. That immutability is what makes the decision history trustworthy.

### `work/README.md` (the item lifecycle + proposal template)

```markdown
# work/ — proposals and in-flight items

One numbered folder per unit of work, proposals included. NNNN is the next
free number across active and archived items; numbers are never reused.

Files inside an item (each optional except whichever starts it):
proposal.md ("should we do this?", status-tracked) · spec.md (pinned
what/why) · plan.md (implementation plan) · notes.md (running notes).

Exit rule: when the work merges or the question resolves, distill anything
durable out (decision rationale → an ADR; reference knowledge → docs/ or a
skill), then move the folder to work/archive/ — or delete it if nothing
durable remains. Archived items are historical records, never current intent.

## Proposal template

# Proposal: <title>

- Status: Draft | In review | Accepted → ADR-NNNN | Rejected
- Author: <name / agent>

## Summary
## Motivation
## Proposal
## Open questions
## Alternatives
```

### `.github/pull_request_template.md`

```markdown
## What & why
<Summary. Link the ADR/proposal/issue this traces back to, if there is one.>

## Checklist
<!-- Skip any line that doesn't apply — not every repo keeps ADRs, a proposal tier, or a CHANGELOG. -->
- [ ] Linked a decision record (ADR / work-item proposal) — if this sets a new direction and the repo keeps them
- [ ] Updated CHANGELOG / docs — if the repo keeps them and this is user-visible
- [ ] Ran the project's checks
- [ ] Touches a high-risk path? Rationale included + reviewer requested
```

---

## New-repo setup checklist

1. Add `AGENTS.md` (use the template), `ARCHITECTURE.md`, `README.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `CODEOWNERS`.
2. Create `docs/adr/` with the template and a first ADR — `0001-record-architecture-decisions.md` — so the practice is self-documenting.
3. Add `.github/pull_request_template.md` and a CI workflow.
4. Add `.claude/settings.json` (permissions + hooks) and the PR template; gitignore `AGENTS.local.md`, `**/AGENTS.local.md`, `.claude/settings.local.json`.
5. Write the thin `CLAUDE.md` (`@AGENTS.md`) next to each `AGENTS.md` by hand — no generator (see "Entrypoint wiring").
6. Keep `AGENTS.md` short. The moment it sprawls, move detail into a skill, an ADR, or a nested `AGENTS.md`.

---

## Applying to an existing repo (brownfield)

The checklist above assumes a blank repo. Most repos aren't blank — they already have a
`README`, some docs, maybe a `CLAUDE.md`, CI, their own conventions. Here the scaffold is a
**target shape to reconcile against**, not a set of files to stamp on top. The core rule:
**the first two phases are read-only, and no file is edited until a human approves a plan.**

Run it as five phases:

1. **Orient (read-only).** Read this reference *and* the whole target repo. Inventory what
   already maps to the scaffold — existing `CLAUDE.md`/`README`/`docs/`/CI/`CODEOWNERS`, any
   decision log or conventions doc — and learn the repo's *actual* patterns.
2. **Gap map (read-only).** For each scaffold piece, record `present (where) / partial /
   absent` → `keep as-is / adopt / adapt / skip`, filtered through the lean-core tiers.
   Reconcile names here: if the repo already has `docs/decisions/`, align to it — don't add
   a parallel `docs/adr/`.
3. **Reconcile the entry point.** If a *substantive* `CLAUDE.md` exists, **promote its
   content to `AGENTS.md` and leave `CLAUDE.md` as the two-line stub** — a move, never a
   flatten. If both exist, merge deliberately. Keep the root lean; push detail into nested
   `AGENTS.md`.
4. **Propose, then get sign-off.** Write the gap map + planned edits as a plan (or an
   `IN_TRANSIT` doc) and stop. Human review is mandatory before any edit that changes
   enforcement (`CODEOWNERS`, CI, branch protection) or touches security-sensitive files.
5. **Apply in safe order, small commits.** Additive/mechanical first (split into
   `AGENTS.md`, add `ARCHITECTURE.md`, nested entry points, gitignore) as one reviewable
   commit; structural/risky changes (renames, path rewrites, CI) as separate *tested*
   commits. Clean tree, review `git diff`, no push without approval. Optionally record the
   adoption as a first ADR so the change documents itself.

**Brownfield guardrails** (in addition to the general ones above):
- **Match existing patterns over the template** — the repo's working conventions win.
- **Don't rename things that work** just to match scaffold names; alias in `AGENTS.md` instead.
- **No empty opt-in dirs** — don't create `work/` (or any proposal tier) "for completeness."
- **Move, never flatten** a substantive file.
- **Read-only until the plan is approved.**