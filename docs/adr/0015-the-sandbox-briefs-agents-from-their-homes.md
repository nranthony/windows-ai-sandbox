# ADR-0015 — The sandbox briefs agents from their global homes, never from a repo

- **Status:** Accepted (2026-09-15; decided on the sibling 2026-09-14)
- **Deciders:** nranthony + agent
- **Work item:** `work/0030-venv-and-notice-replay/` (replaying `macolima@work/0011`)
- **Shared number:** macolima's ADR-0015 is the same decision.
- **Affects:** `sandbox_templates/common/agent-notice.md` (now the shared
  neutral text), `scripts/sync-agent-notice.sh` (neutral marker, legacy
  recognition, `--strip`), `scripts/profile.sh` (two targets on every
  `up`/`recreate`/`rebuild`/`converge`; `NOTICE_SHA` into `verify`),
  `scripts/verify-sandbox.sh`, `scripts/workspace-scan.py` (`NOTICE-IN-REPO`).

## Context

The sandbox notice is the text that tells an agent what fails here, what is a
human step, and how venvs, web reads and databases work. It reached agents by
two routes. One worked: the marker region in each profile's
`claude-home/CLAUDE.md`, regenerated on every `up` and `converge`, which
Claude Code loads in every session. The other did not: a marker block at the
top of a repo's `AGENTS.md`, which the conventions scaffold instructed, which
`docs/index.md` and this repo's `AGENTS.md` described as automated, and which
no verb in either sandbox ever ran.

On this machine **19 checkouts across three profiles** carried such a block on
2026-09-15, every one this sandbox's own marker, none refreshed since it was
placed. The sibling found ten on the Mac, all of them *this* sandbox's block,
contradicting the repos around them (one said `export
UV_PROJECT_ENVIRONMENT=.venv-linux`, two said `uv sync` was denied). Two
defects made them unfixable in place:

- **The block was not neutral.** Each sandbox wrote its own marker
  (`managed by windows-ai-sandbox` / `managed by macolima`), so a sync run over
  the other's block appended a second block instead of replacing it. Measured.
  The two texts differed only in the home path, one venv bullet and two
  contradictory GPU sections; the rest was byte-identical.
- **Repo agents may not edit inside the markers**, by the conventions skill's
  rule. A stale block stayed wrong until a human touched the repo.

Meanwhile agy, the second agent in every profile, had no briefing at all —
"gated but not briefed" was a recorded gap, on the belief that agy had no
global context file to write into.

Measured on the sibling before deciding (2026-09-14):

- Claude Code 2.1.270 loads a `CLAUDE.md` from an ancestor directory of the
  cwd, but does not follow `@` imports inside that ancestor file. The same
  import in the cwd's own file resolves.
- agy 1.2.0's embedded documentation: rules (`AGENTS.md`, `GEMINI.md`, or
  `rules/*.md`) are discovered by walking from the cwd to the repository
  root, and separately from the global customization root `~/.gemini/config/`,
  which "applies to all projects and workspaces". The global path is
  documented, not yet observed loading: the measurement needs an interactive
  sign-in (work/0030 R4).

## Decision

**One neutral notice, written by the sandbox into each agent's global home on
every `up`, `recreate`, `rebuild` and `converge`, and never into a repo.**

- The text names no sandbox and no user: the agent home is `~` (here `/root`,
  on the sibling `/home/agent`), the GPU bullet is "a GPU exists only if
  `/dev/dxg` does" (which covers both substrates; this repo's three CUDA
  bullets are gone from the shared text), and the venv bullet is the rule both
  sandboxes share ([ADR-0013](0013-the-environment-names-the-venv.md)). The
  file is adopted **verbatim** from the sibling; the two repos carry one text.
- The marker is neutral: `managed by the sandbox — do not edit here`. The
  sync script recognises any BEGIN line by **prefix** — the two old markers
  and a hand-written one whose comment wraps across four lines (found in two
  depot repos; a whole-line match cannot see it) — so a migration replaces
  rather than stacks.
- Two targets per profile, both regenerated from the one template:
  `claude-home/CLAUDE.md` (`~/.claude/CLAUDE.md`) and
  `gemini-home/config/rules/sandbox-notice.md` (`~/.gemini/config/rules/`,
  under the `gemini-home` mount at `docker-compose.yml`). Neither points at
  the other.
- No notice block in any repo. Blocks placed by hand are stripped once,
  host-side, with `scripts/sync-agent-notice.sh --strip` (read the region
  first: on the Mac four of ten held repo-authored text inside the markers);
  the workspace scan flags any that return (`NOTICE-IN-REPO`);
  `verify-sandbox.sh` asserts both home files carry the current template, by
  hash handed in from the host as `NOTICE_SHA`, so a stale converge fails
  loudly.
- Update and strip write **into** the target, never `mv` over it, so a repo
  `AGENTS.md` keeps its mode, owner and inode (the first Mac strip landed
  every file at mktemp's 600, unreadable by a container under another uid).

## Consequences

- The "gated but not briefed" gap closes for agy, subject to the measurement
  above. If agy does not load the global rules file, the second target is
  dropped and the gap is re-recorded with the measurement beside it.
- A repo's `AGENTS.md` is the repo's own text, top to bottom. This repo's
  documentation of a per-repo sync (`AGENTS.md`, `docs/index.md`, the sync
  script's own directory-glob example) is retired with this ADR; the
  conventions scaffold's instruction to place a block is a depot handoff, and
  until it lands the scanner flag is the tripwire for a fresh scaffold.
- `verify` passes its first host-computed value into the streamed check
  script. Until now the script could see nothing of the repo.
- **The notice's registry claim is unchanged by this ADR.** The shared text
  says the registries are "closed by default"; on this sandbox `[pypi]` and
  `[pytorch]` are open (work/0025, D1 undecided). Adopting the shared text
  neither fixes nor worsens that; 0025 owns it.

## Rejected alternatives

- **A file at the workspace root** (`/workspace/AGENTS.md` plus a stub). For
  Claude Code the root file would need the full text (imports there are not
  followed); for agy the workspace root is above every repo's `.git`, outside
  its documented walk; the scanner enumerates git repos only. And it would not
  have removed the repo blocks.
- **Neutral per-repo blocks.** Ends the marker fight and keeps the
  unfixable-from-inside rule and the hand-placed drift.
- **Claude's home file importing agy's rules file.** One copy, two coupled
  mounts, and a briefing that disappears if the gemini home is missing.
- **Automating the per-repo sync on `up`.** This repo's own objection stands:
  a container start should not rewrite files in the operator's git tree.
