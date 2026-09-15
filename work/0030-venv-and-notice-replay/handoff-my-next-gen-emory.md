# Handoff: the sandbox names its own venv — retire the `os()` switch in the justfile

**To:** the agent working in `nranthony/my-next-gen-emory` (sandbox profile `nranthony`, `/workspace/my-next-gen-emory`)
**From:** the agent in `windows-ai-sandbox` (host side)
**Date:** 2026-09-15 (final form, written after the switch)
**Reciprocal-to:** your `docs/adr/0021-jobwatch-installable-package.md` (the per-platform venv note) — this amends it.
**Filed at:** `windows-ai-sandbox/work/0030-venv-and-notice-replay/handoff-my-next-gen-emory.md` ·
delivered: `/workspace/inbox/0030/handoff-my-next-gen-emory.md` (the `nranthony`
workspace root, outside every repo; this repo has no `inbox/`)

## 0. Precondition — check before touching anything

```sh
echo "$UV_PROJECT_ENVIRONMENT"
```

It must print **`.venv-sandbox`**. If it prints nothing, **stop and report**:
the switch hasn't reached this container yet. This caveat belongs to this
handoff only; nothing you write into the repo should repeat it.

## 1. What changed

Owner decision, recorded as windows-ai-sandbox **ADR-0013** "The environment
names the venv, not the repo" (macolima's ADR-0013 is the same decision). The
repo-side half is `agentic-conventions` **ADR-0017**, shipped in **myconv
0.9.0** — cite that one here.

**The environment names the venv; a repo never chooses it:**

| Where it runs | `UV_PROJECT_ENVIRONMENT` | Venv |
|---|---|---|
| Any sandbox container | `.venv-sandbox`, exported by compose | `<repo>/.venv-sandbox` |
| Any host — WSL, bare Linux, macOS, CI | **unset** | `<repo>/.venv` |

This repo chooses by platform: `justfile:10` picks `.venv-macos` or
`.venv-linux` from `os()`, and `just sync` exports the variable to match.
**On this sandbox the host and the container are both Linux**, so `os()`
gives both sides the same name and the two environments collide — the exact
failure the rule exists to stop. The scan found two sandbox-built venvs here,
one in `.venv-linux` and an empty one in `.venv` (the host's slot), which is
that collision already under way.

## 2. What does NOT change

- Every recipe stays a thin wrapper over `emory-jobwatch <subcommand>`; the
  `just venv=…` override goes away, because uv already has the one override
  that matters.
- `research/jobs/` ownership rules, the enrichment flow, the metered fetch.
- `.gitignore` already ignores `.venv`, `.venv-*/`; it gets the `.local` lines.

## 3. What to change — checks, not claims

Read from a host-side copy at `e88e700`.

| Where | Now | End state |
|---|---|---|
| `justfile:7-12` | `venv := if os() == "macos" {…} else {…}`; `py := venv / "bin" / "python"`; `jw := py + " -m emory_jobwatch"` | `jw := "uv run emory-jobwatch"` (or `"uv run python -m emory_jobwatch"`), and drop `venv`/`py`. The header comment: "uv picks the venv from `UV_PROJECT_ENVIRONMENT` (ADR-0025); never set it here" |
| `justfile` `test` / `lint` / `fmt` | `{{ venv }}/bin/pytest`, `{{ venv }}/bin/ruff …` | `uv run pytest -q {{ args }}`, `uv run ruff …` |
| `justfile` `sync` | `UV_PROJECT_ENVIRONMENT={{ venv }} uv sync --extra dev` | `uv sync --frozen --extra dev` |
| `README.md:55-66` | the two `export UV_PROJECT_ENVIRONMENT=…` blocks | `uv sync --extra dev` once; one sentence: the sandbox sets the variable, hosts leave it unset |
| `README.md:99-106` | "`just` picks `.venv-linux` or `.venv-macos` from the platform… override with `just venv=…`"; `source .venv-linux/bin/activate` | drop the platform sentence and the override; "activate the venv" → `uv run emory-jobwatch …` |
| `.claude/skills/poll-jobs/SKILL.md:24,67,68` | `PYTHONPATH=src /root/.venv/bin/python3 -m emory_jobwatch …` | `uv run emory-jobwatch …`. `/root/.venv` is the image's baseline interpreter, not this project's venv — the recipe worked only while the project was stdlib-only |
| `docs/adr/0021-…md:43` | "one lockfile, no cross-platform venv fights" via `UV_PROJECT_ENVIRONMENT` | leave; add a one-line amendment pointing at the new ADR |
| new `docs/adr/0025-the-environment-names-the-venv.md` (next free number) | — | context (the `os()` switch collides on a Linux host), decision (table above, citing agentic-conventions ADR-0017), consequences |
| `.gitignore:155-160` | `.venv`, `.venv-linux/`, `.venv-macos/`, `.venv-*/` | `.venv*/` plus `*.local`, `*.local.*`, `!*.local.example*` |
| new `.python-version` | — | `3.12`, tracked (`requires-python >=3.11`; 3.12 and 3.13 are baked; the convention's default is 3.12) |

## 4. Ordered steps

1. §0 precondition.
2. `.python-version` first.
3. The justfile, README, skill, ADR and `.gitignore` edits.
4. **Build the venv:** `uv sync --frozen --extra dev` (streamlit is in `dev`). If
   it fails on the network, **stop and ask the owner** for an egress window.
5. Smoke test: `just stats`, then `just test`. **Don't use `python -c`.**
6. `git grep -n -E '\.venv-(linux|macos)|UV_PROJECT_ENVIRONMENT|os\(\)|/root/\.venv'` —
   nothing left outside `docs/adr/` and `work/`.
7. Commit locally, one commit. The five modified files under `research/jobs/`
   are someone's poll in progress — leave them out of it.

## 5. What has to happen on the sandbox side (do not attempt)

Already done: the compose variable, the deletion-hook exception, the notice,
the verify check. Still the owner's: an egress window if step 4 needs one, and
retiring `.venv/` (sandbox-built, empty) and `.venv-linux/` — human deletions
after a soak; never delete them yourself.

## 6. What to hand back

Via the owner, into `windows-ai-sandbox/work/0030-venv-and-notice-replay/notes.md`:
the commit hash; whether step 4 needed egress; the step-5 result; the ADR
number you took if 0025 was gone.
