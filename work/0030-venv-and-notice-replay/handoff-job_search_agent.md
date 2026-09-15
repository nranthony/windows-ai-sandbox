# Handoff: the sandbox sets `UV_PROJECT_ENVIRONMENT` itself — stop exporting `.venv-linux` over it

**To:** the agent working in `nranthony/job_search_agent` (sandbox profile `nranthony`, `/workspace/job_search_agent`)
**From:** the agent in `windows-ai-sandbox` (host side)
**Date:** 2026-09-15 (final form, written after the switch)
**Reciprocal-to:** your `docs/adr/0002-per-platform-virtualenvs.md` — this supersedes it.
**Filed at:** `windows-ai-sandbox/work/0030-venv-and-notice-replay/handoff-job_search_agent.md` ·
delivered: `/workspace/inbox/0030/handoff-job_search_agent.md` (the `nranthony`
workspace root, outside every repo; this repo has no `inbox/`)

## 0. Precondition — check before touching anything

```sh
echo "$UV_PROJECT_ENVIRONMENT"
```

It must print **`.venv-sandbox`**. If it prints nothing, **stop and report**:
the switch hasn't reached this container yet, and a `uv sync` here would build
into `.venv`, the host's slot. This caveat belongs to this handoff only;
nothing you write into the repo should repeat it.

## 1. What changed

Owner decision, recorded as windows-ai-sandbox **ADR-0013** "The environment
names the venv, not the repo" (the same decision as macolima's ADR-0013). The
repo-side half is `agentic-conventions` **ADR-0017**, shipped in **myconv
0.9.0** — cite that one in this repo.

**The environment names the venv; a repo never chooses it:**

| Where it runs | `UV_PROJECT_ENVIRONMENT` | Venv |
|---|---|---|
| Any sandbox container | `.venv-sandbox`, exported by compose | `<repo>/.venv-sandbox` |
| Any host — WSL, bare Linux, macOS, CI | **unset** | `<repo>/.venv` |

uv reads the variable itself on every `uv run` / `uv sync` / `uv venv`, and a
relative value resolves against the project root. So the repo needs no help:
commands go through `uv run …`, and nothing exports the variable.

This repo got to the same idea first, by hand (ADR-0002): a per-platform name,
`.venv-linux`, chosen by **setting** the variable in `AGENTS.md`, `README.md`
and `.devcontainer/.zshrc`. Now that the sandbox sets it, following those
instructions overrides the sandbox for the whole session and keeps a retired
venv alive without any error. **Selecting by platform was also wrong here in
principle:** this sandbox's host and container are both Linux, so a
per-platform name cannot separate them; only the environment can.

## 2. What does NOT change

- `uv.toml` `no-build = false` stays (your ADR-0005; two dependencies publish
  no wheel). The sandbox's verify reports it as a WARN with the reason recorded.
- `.gitignore` already covers `.venv*`; only the `.local` lines are added.
- `.claude/settings.local.json` is gitignored: the `.venv/bin/python` allow
  rules in it are this machine's accumulated approvals, hygiene not policy.
  Leave them; new rules go in the `uv run …` form.
- The `.env` requirement and the three API keys.

## 3. What to change — checks, not claims

Read from a host-side copy at `c8069fa`.

| Where | Now | End state |
|---|---|---|
| `AGENTS.md:22-56`, "Environment" | "The virtualenv is `.venv-linux`, not `.venv`"; `export UV_PROJECT_ENVIRONMENT=.venv-linux`; the VIRTUAL_ENV-warning paragraph; "installs `jobs` editable into `.venv-linux`" | Short: "Run everything through `uv run …`. The environment picks the venv — host `.venv`, sandbox `.venv-sandbox` — via `UV_PROJECT_ENVIRONMENT`, which you never set yourself. Build or refresh with `uv sync --frozen` (ADR-0006)." Keep the `.env` and `uv.toml` paragraphs |
| `README.md:12-17` | `export UV_PROJECT_ENVIRONMENT=.venv-linux   # .venv on macOS` and the "must be set explicitly" sentence | `uv sync` alone; one sentence: the sandbox sets the variable, hosts leave it unset |
| `.devcontainer/.zshrc:125-128` | `export UV_PROJECT_ENVIRONMENT=.venv-linux` | remove the four lines. A shell rc that exports it overrides the compose value for every command in that shell |
| `docs/adr/0002-per-platform-virtualenvs.md` | Accepted | leave the text; add a status line "Superseded by ADR-0006" |
| new `docs/adr/0006-the-environment-names-the-venv.md` | — | short: context (ADR-0002's premise fails when host and container are both Linux), decision (the table above, citing agentic-conventions ADR-0017), consequences (`uv run …`; never export; `.venv-linux` retired by the owner) |
| `.gitignore` | `.venv*` | add `*.local`, `*.local.*`, `!*.local.example*` beside the `AGENTS.local.md` lines |
| new `.python-version` | — | `3.12`, tracked. `requires-python` allows 3.12–3.13 and both are baked; 3.12 is the convention's default. Say so if you pick 3.13 |

## 4. Ordered steps

1. §0 precondition.
2. `.python-version` first — unpinned, uv takes 3.13 and the venv is rebuilt when the pin lands.
3. The five edits in §3.
4. **Build the venv:** `uv sync --frozen`. Packages come from the cache or from
   PyPI through the proxy. If it fails on the network, **stop and ask the
   owner** for an egress window.
5. Smoke test through the repo's own code: `uv run pytest -q`. **Don't use
   `python -c`:** the policy denies it.
6. `git grep -n -e '\.venv-linux' -e 'UV_PROJECT_ENVIRONMENT='` — nothing left
   that sets the variable or runs `.venv-linux`, outside `docs/adr/0002`.
7. Commit locally, one commit.

## 5. What has to happen on the sandbox side (do not attempt)

Already done: the compose variable, the deletion-hook exception, the notice,
the verify check. Still the owner's: an egress window if step 4 needs one, and
retiring `.venv-linux/` (a human deletion, after a soak — never delete it
yourself; `rm -rf` is denied regardless).

## 6. What to hand back

Via the owner, into `windows-ai-sandbox/work/0030-venv-and-notice-replay/notes.md`:
the commit hash; whether step 4 needed egress; the step-5 result.
The sandbox then re-runs `just workspace-scan --fail-on HARDCODED-VENV-LINUX,OS-VENV-SELECT`
host-side; this repo must no longer appear.
