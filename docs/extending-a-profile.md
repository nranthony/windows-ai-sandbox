# Extending a profile — where a capability has to live

How a tool, skill, plugin, library, credential or API reach an agent inside a
profile. This is the *deployment* question, distinct from the *permission*
question (`docs/permissions-model.md`) and the *egress* question
(`.agents/skills/squid-management.md`): those say whether the agent may use a
thing, this says how the bytes get there and what erases them.

Read this before designing anything whose install story is "run the vendor's
one-liner". Most of those one-liners assume a normal host: writable `$HOME`, an
open network, and a per-user install prefix. This sandbox breaks all three in
specific, discoverable ways, and the failure mode is usually *silent
disappearance on recreate* rather than an error.

## The model in one screen

Three places bytes can live, two gates they must pass.

| Layer | Path | Shared by | Erased by |
|---|---|---|---|
| **Image** | anything not listed below | every profile | nothing (rebuild replaces it) |
| **Container writable layer** | `/usr`, `/opt`, `/etc`, `/root/*` not bind-mounted | one container | `docker rm` — i.e. `recreate`, `rebuild`, `down`+`up` |
| **tmpfs** | `/tmp`, `/run`, `/root/.local`, `/root/.npm-global` | one container | container *stop*; also `noexec` |
| **Per-profile state** | `~/.ai-sandbox/profiles/<p>/…` → `/root/.claude`, `/root/.config`, `/root/.cache`, `/root/.gemini`, `/root/.kaggle`, `/root/.claude.json` | one profile | only `profile.sh <p> wipe` |
| **Workspace** | `~/repo/<p>/` → `/workspace` | one profile | nothing (it's your git tree) |
| **Named volume** | DB data dirs | one profile | `db-reset`, `wipe --all-volumes` |

The two gates:

- **Egress** — Squid allowlist (`proxy/allowed_domains.txt`). Registries are
  closed by default ([ADR-0003](adr/0003-strict-egress-default.md)); a
  dependency enters only through a `scripts/with-egress.sh` window. DNS is
  sinkholed, so hosts not in the allowlist do not resolve, let alone connect.
- **Agent tool policy** — `claude-home/settings.json` deny-list plus the
  `deny-destructive` PreToolUse hook. This binds *Claude's Bash tool only*. The
  human's attached zsh (`profile.sh <p> attach`) is unrestricted by it — but
  still subject to egress. That asymmetry is the deployment lever: installs are
  a human step in an attached shell or a `with-egress.sh` window, not an agent
  step.

**The rule that catches people:** a bind mount *shadows* whatever the image put
at that path. `COPY`ing a skill to `/root/.claude/skills/` in the `Dockerfile`
produces a file no container will ever see, with no error at build or run time.
Same for anything under `/root/.config` — which is why the pnpm quarantine
setting is written host-side by `ensure_state`, not baked into the image.

## Decision table — where does it go?

| You want to add | Layer | Mechanism | Survives `recreate`? |
|---|---|---|---|
| A system package / CLI binary for every profile | image | `Dockerfile` + `profile.sh build` | yes |
| A CLI binary for one profile, one session | writable layer | attached shell inside a `with-egress.sh` window | **no** — re-do or promote to the image |
| An agent skill | per-profile | `sandbox_templates/skills/<name>/` → seeded to `claude-home/skills/` | yes |
| A Claude Code plugin / marketplace | per-profile | `claude-home/plugins/` (see below) | yes |
| Agent tool policy (allow/deny/hooks) | per-profile | `sandbox_templates/claude/` → `claude-home/settings.json` | yes |
| Standing instructions for every repo in a profile | per-profile | `claude-home/CLAUDE.md` via `scripts/sync-agent-notice.sh` | yes |
| Standing instructions for one repo | workspace | that repo's `AGENTS.md` / `.claude/` | yes |
| A Python dependency of a project | workspace | the project's `.venv` + manifest, installed in a `with-egress.sh` window | yes (`.venv` is in the bind mount) |
| A Python lib that isn't on PyPI | workspace | `~/repo/<p>/dist/*.whl` — [local-wheels.md](local-wheels.md) | yes |
| An API key | per-profile | `~/.ai-sandbox/profiles/<p>/secrets.env` | yes, but read at container **create** only |
| Reachability of a new host | egress | `proxy/allowed_domains.txt` block, tagged `[name]` | yes (repo-level, all profiles) |
| A database | sibling container | `COMPOSE_PROFILES=db-postgres profile.sh <p> up` | data in a named volume |
| A device or published port | compose overlay | `docker-compose.wsl-gpu.yml` / `.expose-dev.yml` | yes |
| An MCP server | per-profile | `claude.json` / `claude-home` config + allowlist entry for its host | yes |

## Seam notes — the non-obvious parts

### Image layer (`Dockerfile`)

One image, all profiles: adding here is a fleet-wide change and costs a build.
Two constraints beyond the usual:

- **Install order is load-bearing.** beads < claude/agy < npmrc (Gate 2) <
  uv/pip (Gate 3), locked by `scripts/dockerfile-order.test.sh`. Gate 2's
  `min-release-age` applies at *build* time too, so a quarantine written above
  a `@latest` CLI install makes that install intermittently unresolvable.
- **Install prefixes are deliberate, not incidental.** `/root/.local` and
  `/root/.npm-global` are 256m/512m `noexec` tmpfs at runtime, so anything
  installed there is both wiped and unrunnable. The image therefore pins
  `UV_TOOL_DIR=/opt/uv/tools` with `UV_TOOL_BIN_DIR=/usr/local/bin`, and npm's
  `prefix=/usr`. A vendor installer that defaults to `~/.local/bin` needs its
  prefix overridden, or it will "install successfully" and then fail with
  `EACCES` on first run.

`profile.sh build --refresh-ai` rebuilds only the AI-CLI tail layer — use it
for CLI version bumps, not for new tooling.

### Per-profile agent state (`claude-home`)

Skills **converge** to the template tree on every `up`
([ADR-0005](adr/0005-skill-templates-are-source-of-truth.md)):
`sandbox_templates/skills/` is the source of truth, `claude-home/skills/` is a
derived cache. Consequences:

- a **new or edited** skill lands on the next `up`; a skill **removed** from the
  template is pruned from every profile;
- a locally edited copy is **replaced, with a WARN** — no backup is kept, because
  a `<name>.bak.<stamp>` inside the scanned directory is a second live copy of
  the skill (and for a skills-dir plugin, the backup wins the name race);
- a directory the sandbox never seeded is left alone — `claude plugin init`
  scaffolds into `~/.claude/skills/<name>/`, so pruning is scoped to `*.bak.*`
  and names in `claude-home/skills/.sandbox-seeded`;
- **settings are still create-only** — `profile.sh <p> reset-settings` re-seeds
  `settings.json` from the template, and that one does keep a `.bak`, outside the
  skills directory;
- restart `claude` in the container to pick any of it up.

Intentional per-profile variation therefore has a different home: per-repo
`.claude/skills/` in the workspace (project scope, git-tracked), or the template
itself. Personal scope is not a customisation surface.

`sandbox_templates/skills/` mixes sandbox-native skills with copies vendored
from `agentic-conventions` — `UPSTREAM.md` says which. Edit vendored ones
upstream; the next `just vendor-tools` reverts local edits silently.

### Plugins and marketplaces

Claude Code stores marketplaces as git clones under
`/root/.claude/plugins/marketplaces/<name>`, tracked in
`plugins/known_marketplaces.json` — all inside the per-profile bind mount, so a
plugin installed in a profile persists across recreates, and a plugin
pre-populated host-side under `~/.ai-sandbox/profiles/<p>/claude-home/plugins/`
is visible in the container.

`/plugin marketplace add <owner>/<repo>` works **inside** a profile today
because `github.com`, `api.github.com` and `codeload.github.com` are
allowlisted. What is *not* allowlisted by default:
`raw.githubusercontent.com`, `objects.githubusercontent.com`,
`release-assets.githubusercontent.com`. So a marketplace cloned over HTTPS
resolves; a plugin that pulls release assets or raw files does not, and fails
as a connection error, not a 404. Nothing in `profile.sh` seeds plugins — if a
plugin should ship to every profile, that is a new `ensure_state` seam
(mirroring the skills loop), not something to hand-place per profile.

### Secrets and env

`secrets.env` and `db.env` are injected as optional `env_file`s — **read at
container create only**. Editing either and running `up` changes nothing for a
running agent; `profile.sh <p> recreate` is required. A key is useless without
its host in the allowlist, and variable *names* are dictated by the consuming
code, not by taste — a plausible synonym reads as unset and fails as "no key".

### Egress additions

Prefer a `with-egress.sh --with <tag>` window over a permanent allowlist entry:
it opens the tagged block, hot-reloads Squid, runs one command, restores the
file verbatim, and writes an audit line to
`profiles/<p>/audit/depgate.jsonl`. Permanent entries are pinned subdomains
under the right lifecycle tier, and the proxy must be reloaded before they take
effect — grepping the file inside the container tells you what it *says*, not
what Squid *enforces*.

### Ephemeral by design

`scripts/run-ephemeral.sh <p>` gives a `--rm` container on the profile's
network with the same hardening — right for a one-shot tool trial, wrong for
anything you want tomorrow.

## Worked patterns

**A new agent capability (skill).** Author under
`sandbox_templates/skills/<name>/SKILL.md` → `profile.sh <p> up` (or
`reset-skills` to converge without touching the container) → restart `claude`.
Never `COPY` it into the image. A directory carrying
`.claude-plugin/plugin.json` is seeded by the same path and loads as
`<name>@skills-dir`, so a plugin needs no separate mechanism.

**A new external service the agent must call.** Allowlist its pinned host under
the right tier → reload the proxy → add the key to `secrets.env` with the exact
variable name its consumer reads → `recreate` → probe from inside the container
before wiring any logic. Four steps, and skipping the `recreate` is the usual
cause of "the key is set but unset".

**A shared library that is not published.** Build a wheel on the host, drop it
in `~/repo/<p>/dist/`, install from `/workspace/dist/` inside the container, and
declare it in `[tool.uv.sources]` with a platform marker — otherwise the next
`uv sync` removes it. Do not widen egress to a private index for this.

**A private CLI the whole fleet needs, shipped as a wheel.** The pattern
`myclickup` establishes, and the one to copy for any sibling tool: build a
zero-dependency wheel, vendor it into `sandbox_templates/wheels/` with a
host-side script, install it in the `Dockerfile` tail. Four things make it work,
and each is a trap if skipped:

1. **`build.context: .` is the whole reason for vendoring.** `COPY` cannot read a
   sibling checkout however the host is laid out, and a network install would put
   a deploy token inside the build of a security-critical image.
2. **A gitignored payload needs a directory `COPY` and a conditional install.**
   `COPY …/foo-*.whl` is a hard build failure when the glob matches nothing, so
   the paste-obvious form breaks every clone that lacks the payload. Keep a
   `.gitkeep` so the directory exists in the context. The trade is explicit: the
   image is no longer reproducible from a clone alone.
3. **The wheel and its skill are one payload.** The skill describes a tool
   *version* — its commands, its flags — so a hand-copied skill drifts from the
   CLI, and a stale skill is worse than none: it sends an agent to run commands
   that no longer exist, in a container where it cannot install a fix. Vendor
   both, and have the check compare **content, not version strings** (pre-1.0 the
   version changes rarely and the tree changes constantly, so the common drift is
   a rebuilt same-version wheel with different bytes).
4. **A vendored wheel is not a vendored skill, lifecycle-wise.** The skill
   converges on the next `up`; the wheel is baked into the image, so it needs
   `profile.sh build` and then a recreate. `up` does not rebuild.

Two things bite in practice. Zero runtime dependencies is an invariant, not a
starting point — the agent cannot repair a broken dependency, since every
installer is denied to it. And if the tool's source repo is bind-mounted into a
profile, its `.venv` may have been created in-container, where console scripts
carry an absolute `#!/workspace/...` shebang; a host-side build then fails with
"Failed to spawn: pytest", which reads like a missing dev dependency rather than
a path mismatch. Point `UV_PROJECT_ENVIRONMENT` outside the checkout rather than
rebuilding a `.venv` that the container also uses.

**A tool the whole fleet needs.** Prototype in an attached shell inside a
`with-egress.sh` window, confirm the install prefix is exec-capable and
persistent, then promote it to the `Dockerfile` at the correct point in the
gate order and run `dockerfile-order.test.sh`. Prototype state dies on the next
recreate — that is the design, not a bug to work around.

**A per-project toolchain (node/python/rust versions).** Belongs in the project
in `/workspace`, pinned by its own manifest and lockfile. The image is the
floor, not the toolchain manager. Note `manage-package-manager-versions=false`
is set per profile: repo `packageManager` pins are deliberately ignored inside
the sandbox because pnpm's version manager re-execs from a `noexec` tmpfs.

## Verify what you added

```bash
scripts/profile.sh <p> verify        # tier 1 tripwire — mounts, gates, identity
scripts/profile.sh <p> audit         # tier 2 structured probes
scripts/profile.sh <p> deps [--osv]  # dependency posture; --history for install windows
```

Security-sensitive files (`Dockerfile`, compose, `seccomp.json`, `proxy/`,
`sandbox_templates/claude/`, the scripts named in `AGENTS.md`) carry the
verification protocol in `AGENTS.md` — state the security impact in the commit
and run at least tier 1.

## Portable brief — for an agent outside this repo

Self-contained; paste it into another repo's planning context when that repo's
work has to run inside a profile. It assumes no access to this tree.

> **Deploying into `windows-ai-sandbox` — what you can assume**
>
> 1. **Three durability classes.** The repo tree (`/workspace`) and the agent's
>    home (`/root/.claude`, `/root/.config`, `/root/.cache`) are host bind
>    mounts and persist. Everything else in the filesystem — `/usr`, `/opt`,
>    a globally installed CLI — lives in the container layer and is destroyed on
>    the next recreate. `/tmp`, `/root/.local`, `/root/.npm-global` are
>    additionally `noexec` tmpfs: things "install" there and then cannot run.
>    **Design so the durable artifact is a file in the repo or in the agent
>    home, never an installed binary.**
> 2. **Network is allowlist-only, registries closed.** No arbitrary HTTP; no
>    `pip`/`npm`/`cargo` install; `github.com`, `api.github.com`,
>    `codeload.github.com` are open but `raw.githubusercontent.com` and
>    release-asset hosts are not. Anything needing a fetch at install time must
>    be a human step (a bounded egress window) — so **prefer designs where
>    material arrives as files in a git-tracked tree over designs that install
>    at first use.**
> 3. **Remote git is denied to the agent.** Commit locally; a human pushes. Any
>    distribution scheme whose first step is "push a repo" has a human in it.
> 4. **The agent's home is per-profile and pre-seedable.** Skills live at
>    `~/.claude/skills/<name>/SKILL.md`, plugins/marketplaces at
>    `~/.claude/plugins/`, global standing instructions at `~/.claude/CLAUDE.md`
>    — all inside the persistent mount, all placeable from the host before the
>    container starts. That host-side pre-population is the supported way to get
>    an agent-facing capability into a closed-egress profile.
> 5. **Instructions beat automation.** The sandbox deliberately ships
>    *instructions an agent applies with judgment*, not scripts that mutate a
>    target repo unattended. A capability shaped as "a skill plus reference
>    material the agent reads" installs cleanly here; one shaped as "a
>    deploy script that rewrites files in place" does not, and will be rejected
>    on review even where it would technically run.
> 6. **Ask, don't route around.** A permission denial or a connection error on
>    an unlisted host is the boundary working. Surface it as a human step with
>    the exact host or command needed; retries, shell escapes, and alternate
>    fetch paths are all separately blocked and logged.

## See also

- [ARCHITECTURE.md](../ARCHITECTURE.md) — mounts, network model, state layout
- [.agents/skills/profile-lifecycle.md](../.agents/skills/profile-lifecycle.md) — the commands
- [.agents/skills/squid-management.md](../.agents/skills/squid-management.md) — allowlist edits
- [permissions-model.md](permissions-model.md) — what the agent may do once the bytes are there
- [local-wheels.md](local-wheels.md), [web-read-broker.md](web-read-broker.md)
- [ADR-0003](adr/0003-strict-egress-default.md), [ADR-0004](adr/0004-python-wheels-only.md)
</content>
</invoke>
