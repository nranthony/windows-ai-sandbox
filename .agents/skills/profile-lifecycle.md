# Skill: Profile Lifecycle

`scripts/profile.sh` is the single entry point for everything below — never
call `docker compose` directly (it exports `PROFILE`/`COMPOSE_PROJECT_NAME`,
allocates the per-profile subnet octet, and layers compose overlays; bypassing
it breaks all three).

## First-time bring-up

```bash
mkdir -p ~/repo/<profile>                       # workspace dir (holds many repos)
scripts/profile.sh <profile> up                 # agent + egress-proxy
scripts/profile.sh <profile> attach             # zsh into container
scripts/profile.sh <profile> auth               # claude login (one-time)
scripts/profile.sh <profile> auth-github        # gh auth login
scripts/profile.sh <profile> auth-gitlab       # glab auth login
scripts/profile.sh <profile> auth-antigravity   # Antigravity (agy) console sign-in
```

## Day-to-day

```bash
scripts/profile.sh <profile> attach|down|logs|status
scripts/profile.sh list                         # all profiles + up/down status
scripts/profile.sh <profile> exec <cmd...>      # one-off command in the container
```

`exec` runs `docker exec -it`, so it **needs a terminal on stdin**. From a
script, a CI step, or an agent's non-interactive shell it fails with
`cannot attach stdin to a TTY-enabled container because stdin is not a
terminal` — which reads like a container fault and is not one. For a
non-interactive read, go straight to the daemon:

```bash
DOCKER_HOST=unix:///run/user/1000/docker.sock \
  docker exec ai-sandbox-<profile> <cmd...>      # no -it
```

That is a read against an already-running container, not a lifecycle
operation, so it does not conflict with golden rule 1 — never use it to
create, recreate or remove anything.

GPU: `up`/`recreate`/`rebuild` auto-layer `docker-compose.wsl-gpu.yml` when
`/dev/dxg` exists (WSL2). `SANDBOX_GPU=0` suppresses, `SANDBOX_GPU=1` forces.
Bare-Linux hosts need nothing — the base compose comes up GPU-less.

## Image builds

```bash
scripts/profile.sh build                        # rebuild shared image (all profiles)
scripts/profile.sh build --refresh-ai           # fast: bump Claude Code + agy (tail layer only)
scripts/profile.sh build --claude-version=1.2.3 # pin Claude Code (implies --refresh-ai)
scripts/profile.sh build --refresh-ai --recreate-running  # bump + roll running profiles
scripts/profile.sh recreate-all                 # force-recreate every RUNNING profile
scripts/profile.sh <profile> rebuild [--refresh-ai] [--expose-dev]
```

`--no-cache` / `--pull` are accepted by build/rebuild. `--expose-dev` layers
`docker-compose.<profile>.expose-dev.yml` (LAN port publishing — UNSAFE, may
drop network isolation).

## State hygiene

```bash
scripts/profile.sh <profile> clean              # prune rotating state
scripts/profile.sh <profile> clean --deep       # + MCP logs + settings backups
scripts/profile.sh <profile> converge           # re-converge every agent's policy + skills (see below)
scripts/profile.sh <profile> converge --defaults  # ... and RESET the preserved preferences to the template
scripts/profile.sh <profile> wipe [--dry-run|--yes|--all-volumes]  # blank slate, KEEPS auth
```

`down` also age-prunes MCP logs + session transcripts older than
`SANDBOX_LOG_RETENTION_DAYS` (default 14).

### `converge` — one command, per-agent write modes, build first

`up`/`recreate`/`rebuild`/`wipe` already converge every agent's policy; this is
the same operation without touching the container
([ADR-0007](../../docs/adr/0007-policy-templates-are-source-of-truth-for-every-agent.md),
extending [ADR-0005](../../docs/adr/0005-skill-templates-are-source-of-truth.md)).
It replaced `reset-settings`, `reset-skills` and `reset-antigravity` on
2026-08-24; there are no aliases, so an old script calling one of those fails
loudly rather than silently doing nothing.

Four files, three write modes, and the differences are load-bearing:

- `claude-home/settings.json` — **overwritten**. `env`, `hooks`, `permissions`
  and `sandbox` are sandbox-owned, and the live file simply becomes the
  template. Everything else it held is written to
  `claude-home/settings.discarded.json` first — including the content diff of a
  sandbox-owned key, which is how an in-session "always allow" that landed in
  `permissions` gets recorded rather than silently reverted. You are warned once
  per *change* in that set, not on every run. **Four keys are kept**:
  `skipAutoPermissionPrompt` (user-or-managed scope: a repo file cannot hold it)
  plus `model`, `effortLevel` and `agentPushNotifEnabled` (owner decision
  2026-08-24 — re-picking a model after every `up` is friction with no security
  value). Preserve has two halves: a live value survives, and a live file that
  *lacks* the key takes the template default — `opus` / `medium` / `false`. A
  live preference that differs from the template is **not** drift, and neither
  tier reports it as such.
- `gemini-home/antigravity-cli/settings.json` — **merged**, only `permissions`
  and `toolPermission`. `agy` writes `colorScheme`, `model` and
  `trustedWorkspaces` into that same file during ordinary use, and it has **no**
  per-repo settings surface of any kind, so overwriting it would discard the
  user's settings with nowhere to restore them from.
- `gemini-home/config/hooks.json` — **replaced**. Ours alone.
- `claude-home/skills/` — **mirrored** from the template tree (ADR-0005).

None of the file modes is a directory mirror. `gemini-home/config/` also holds
`config.json`, `mcp_config.json`, `.migrated` and `projects/` — live `agy` state
that a mirror would delete — and `claude-home/` holds plenty the sandbox never
seeded.

**`--defaults` is the one flag `up` never passes.** It inverts the first half of
preserve for one run: the template defaults overwrite the live preferences
instead of the other way round, and the replaced values go to
`settings.discarded.json` under `preference_resets`. Use it when a profile's
preferences have drifted somewhere you do not want; it is an operator action, so
it always says what it reset, never silently.

**Restart `claude`/`agy` in the container afterwards.** Converging under a live
session is a lost-update race in both directions: the session can write its
in-memory settings back over the converge, and the converge can revert a grant
the session just made. `converge` says so when the container is running.

**Nothing here reaches the hook ENGINE.** It is baked into the image and needs
`build` + recreate. Policy converges on `up`, the engine does not — that split
is the single most common confusion about this system.

**Run `build` before this on a fresh clone.** The hook engine
(`/usr/local/lib/sandbox-hooks/guardrails.sh`) is baked into the image. A
`hooks.json` naming a script the image does not have is not an error to `agy` —
it logs and carries on **unguarded**. `verify` asserts the engine is present,
which is the check that catches this; the static `permissions.deny` still
applies either way.

To confirm the policy is live, ask `agy` to run something denied and read the
error rather than trusting the file:

```bash
scripts/profile.sh <profile> verify | grep antigravity
```

## Agent skills in a profile

Skills are **seeded per profile, never baked into the image** — the profile's
`claude-home` bind mount shadows `/root/.claude`, so anything `COPY`d there in
the `Dockerfile` is invisible at runtime.

Seeding **converges** ([ADR-0005](../../docs/adr/0005-skill-templates-are-source-of-truth.md)):
`sandbox_templates/skills/` is the source of truth and the profile's copy is a
derived cache, so every `up` reconciles it. A NEW or EDITED skill lands on the
next `up`; a skill REMOVED from the template is pruned. Restart `claude` in the
container to pick it up.

No backups are taken, and a divergent copy is replaced with a WARN naming it —
recover local edits from git, or make the edit in the template. A
`<name>.bak.<stamp>` inside `claude-home/skills/` would be a second LIVE copy of
the skill (for a skills-dir plugin the backup wins the name race), so stale ones
are pruned on sight. Directories the sandbox never seeded — e.g. `claude plugin
init` output — are reported and left alone.

`converge` runs the same convergence without touching the container.

`sandbox_templates/skills/` mixes sandbox-native skills (this repo is their
source of truth) with material VENDORED through the depot channel —
`sandbox_templates/skills/UPSTREAM.md` says which is which. Edit a vendored
skill upstream, not here; the next vendor silently reverts local edits. Refresh
host-side, never during a build:

A vendored entry may be a loose skill or a **plugin** — a directory carrying
`.claude-plugin/plugin.json`, which loads as `<name>@skills-dir` with its own
skills namespaced (`/myconv:make-plan`, not `/make-plan`). The sync validates
each shape on its own terms and defaults to the plugin surface; upstream's loose
`templates/.claude/skills/` copies of `make-plan`/`wrap-up` are deliberately NOT
vendored, since the plugin supersedes them and carrying both re-creates the
duplicate-procedure drift. Check with `claude plugin list` inside the container.

```bash
just vendor-tools              # consume the channel: wheel, skills, plugin trees
just tools-check               # has the channel moved ahead of VENDORED.lock?
```

Channel path comes from `$DEPOT_DIR` or the gitignored `.depot-dir.local`; the
script writes only the template tree, so follow it with `converge` per
profile to push edits into a live profile.

`sandbox_templates/skills/myclickup/` arrives the same way, pair-vendored with
its wheel so the text can never describe a version the image does not have. A
local edit there is reverted by the next vendor run — `just tools-check` fails
on the drift first, and it fails on CONTENT, not just on a hash: it extracts the
wheel and diffs it against the source commit the manifest claims, whenever the
member checkout is reachable.

## Vendored wheels (private tools)

```bash
just vendor-tools              # consume the channel into the build context (verifies every hash first)
just tools-check               # fail if the lock fell behind, or an artifact disagrees with its source
scripts/profile.sh build       # bake it into the shared image  <-- `up` does NOT rebuild
scripts/profile.sh <p> recreate  # per profile; also re-reads secrets.env
```

The payload (`sandbox_templates/wheels/*.whl`, `sandbox_templates/skills/myclickup/`)
is **gitignored**: this repo is public, `myclickup` is private, and a
`py3-none-any` wheel is a zip of the source. So a fresh clone has no payload —
the `Dockerfile` installs conditionally and the resulting image simply has no
`myclickup`. Source path: `$MYCLICKUP_DIR` or `.myclickup-dir.local`.

Order is load-bearing in one place: **vendor before build.** The skill half
converges like any other on the next `up`, but the wheel half only exists in a
freshly built image, and a converged skill in front of a missing CLI is exactly
the failure the vendoring couples them to avoid.

If the source repo is also bind-mounted into a profile, it has two venvs and
no shared one ([ADR-0013](../../docs/adr/0013-the-environment-names-the-venv.md)):
the host's `.venv` and the container's `.venv-sandbox`. A `.venv` whose console
scripts carry `#!/workspace/...` shebangs is a pre-rule leftover built
in-container — host-side it surfaces as `Failed to spawn: pytest`, which reads
as a missing dev dependency — and is retired (human deletion after a soak),
never rebuilt in place. The vendor script sidesteps all of it with its own
absolute `UV_PROJECT_ENVIRONMENT` outside the checkout; an explicit value there
wins over the environment's, so don't "fix" it.

## Databases (opt-in siblings)

```bash
scripts/profile.sh <profile> db enable postgres|mongo|all   # persist the default
scripts/profile.sh <profile> up                             # now includes the sibling
scripts/profile.sh <profile> db disable                     # stop starting it
scripts/profile.sh <profile> db-reset            # wipe postgres volume, fresh initdb
```

Credentials: copy `sandbox_templates/common/db.env.template` to
`~/.ai-sandbox/profiles/<profile>/db.env` and fill in. The agent reaches them
at `postgres:5432` / `mongo:27017` (static IPs via extra_hosts).

NOTE: `db enable` **persists** the choice (a token in the profile's
`compose-profiles` file, which is a comma list shared with `ollama`), so a plain
`up` starts the sibling from then on. `COMPOSE_PROFILES=...` in the environment
is a one-shot override for a single command, not the normal route.

## Local inference (Ollama sibling)

An air-gapped Ollama per profile, on `sandbox-internal` only. The agent reaches
it at `http://ollama:11434` (static IP `.40` via `extra_hosts`, and in `NO_PROXY`
so it goes direct rather than through Squid). The sibling itself has **no
outbound path at all**: no default route off the internal network, no proxy
variables, no published port. It cannot pull at runtime, and it cannot phone
home.

```bash
scripts/profile.sh <profile> ollama enable      # persist the `ollama` compose token
scripts/profile.sh <profile> up                 # starts ollama-<profile>
scripts/profile.sh <profile> ollama status      # persisted default + container state
scripts/profile.sh <profile> ollama disable
scripts/profile.sh health                       # no profile arg; covers ollama-<p>
                                                # like the DB siblings
```

`just ollama <profile> ...` is the alias.

### Models come in host-side, never from inside

```bash
scripts/profile.sh <profile> ollama pull qwen3-coder
scripts/profile.sh <profile> ollama list
scripts/profile.sh <profile> ollama create <name> -f <Modelfile>   # local GGUF
scripts/profile.sh <profile> ollama rm <model>
```

These run a `--rm` container on Docker's **default bridge** with the store
mounted read-write — a host-side operator action *outside* the sandbox boundary,
the same class as `docker pull`. The agent has no docker socket, so it can never
invoke them. Each pull appends to `pull.log`.

The store is **shared by every profile** at `~/.ai-sandbox/models/ollama/`
(`manifests/`, `blobs/`, `pull.log`) to avoid duplicating multi-GB blobs, and it
is mounted **read-only** at `/models` in every running sibling. Read-only is what
makes sharing safe: Ollama's API has create/delete/copy/blob-upload, so a shared
writable store would let profile A plant a Modelfile system prompt that profile B
then runs.

GPU is the same wiring the agent gets, and only from the WSL overlay
(`/dev/dxg`, `/usr/lib/wsl`); bare Linux runs it CPU-only. There is no
`OLLAMA_KEEP_ALIVE` override — Ollama's 5-minute default releases the card when
a profile goes idle, which matters on one 12 GB GPU shared by every profile.

### Pointing Claude Code at it (per profile)

Claude Code has a documented "LLM gateway" path: `ANTHROPIC_BASE_URL` at
anything speaking the Messages API. Ollama ≥ 0.14.0 does; OpenRouter does. The
switch is a command that writes a managed `backend.env` in the profile's state
dir, injected after `secrets.env`:

```bash
scripts/profile.sh <profile> backend ollama --model qwen3-coder       # the sibling
scripts/profile.sh <profile> backend openrouter --model anthropic/claude-sonnet-4.5
scripts/profile.sh <profile> backend anthropic                        # back to default
scripts/profile.sh <profile> backend status                           # + "pending recreate" if the live agent differs
```

`just backend <profile> ...` is the alias. For OpenRouter, put
`OPENROUTER_API_KEY=...` in `secrets.env` first; the command copies it into
`backend.env` as the bearer token and never takes it on the command line. The
`--model` value fills all three aliases (opus/sonnet/haiku); `--context
<tokens>` sets `CLAUDE_CODE_MAX_CONTEXT_TOKENS` for a model Claude Code does
not recognise (it otherwise assumes 200k).

It is **not** in the settings template, whose `env` block is sandbox-owned and
overwritten on every `up`
([ADR-0007](../../docs/adr/0007-policy-templates-are-source-of-truth-for-every-agent.md)),
and not in `secrets.env`, which is operator-owned and never rewritten by a
script. `backend.env` is preserved across `wipe` like the other auth files.

`env_file` is read only at container CREATE, so nothing changes until
`scripts/profile.sh <profile> recreate`. Pass `--recreate` to the command to
run it immediately. A recreate ends every live shell and any VS Code attach in
that profile; sessions resume from disk, processes do not. `verify` prints
which backend the profile is on.

Caveats, all documented rather than assumed:

- Anthropic documents the gateway mechanism but names neither vendor; Ollama and
  OpenRouter each document the recipe themselves.
- A non-first-party base URL turns MCP tool search off by default, makes Remote
  Control and server-managed settings unavailable, and passes model IDs through
  unvalidated.
- Community measurements put local-model edit accuracy around 70–80 % against
  ~98 % for Sonnet. OpenRouter's own caveat is that Claude Code is optimised for
  Anthropic models.
- Ollama recommends **≥32K context** (64K for large repos); the aliases must
  name a model that has actually been pulled.
- Open issue `ollama/ollama#13949` — Claude Code calls
  `/v1/messages/count_tokens`, Ollama 404s, and the server was reported to wedge
  afterwards. **Measured 2026-09-03 against the pinned 0.33.3 image: the
  endpoint still 404s, the server does not wedge**, and a `claude -p` session
  completed four `/v1/messages` round-trips against `qwen3:0.6b`.

**What does not change:** every control here is on the harness, not the model —
deny lists, the hook engine, seccomp, the egress allowlist. Swapping the model
underneath changes none of them.

## Ephemeral one-shot container

```bash
scripts/run-ephemeral.sh <profile> [command...]   # --rm container, same hardening,
                                                  # attached to the profile's sandbox-internal
```

Stack must already be up (borrows the running Squid). Everything outside bind
mounts is discarded on exit.

## GPU/CUDA smoke test

```bash
scripts/profile.sh <profile> exec bash -lc '
  cd /workspace/windows-ai-sandbox/container_testing && uv sync && \
  uv run python -c "import torch; print(torch.cuda.is_available())"
'
```

Expected: `True` on WSL2+GPU; `False` on bare-Linux hosts (correct, not a bug).

## `just` front door (optional)

Every recipe is a thin pass-through (`just up <p>` → `scripts/profile.sh <p> up`).
It holds NO logic and must never call `docker compose` directly. When adding or
renaming a profile.sh command, update the matching recipe and re-run `just --list`.
