# windows-ai-sandbox

Hardened multi-profile AI development sandbox: one shared image, many
per-profile agent containers, each with its own persistent auth/config and
Squid-gated egress. Runs on **two substrates** — Windows/WSL2 with GPU, and
bare Ubuntu Linux without — auto-detected by `scripts/profile.sh` (signal:
`/dev/dxg`; override `SANDBOX_GPU=0|1`). The security boundary (rootless
Docker: container UID 0 ↔ host UID 1000) is identical on both.

**This is security-critical infrastructure. Source of truth is config, not
code**: `docker-compose.yml`, `seccomp.json`, `proxy/`, `sandbox_templates/claude/`.

## System architecture

Diagrams, network model, state layout, security posture, repo map:
[ARCHITECTURE.md](ARCHITECTURE.md).

## Subprojects

Implementation details stay local to keep this file small:
- **Control dashboard** (Streamlit): [dashboard/AGENTS.md](dashboard/AGENTS.md)
- **CUDA verification** (uv project): [container_testing/AGENTS.md](container_testing/AGENTS.md)

## Golden rules

1. **`scripts/profile.sh` is the single lifecycle entry point.** Do NOT call
   `docker compose` directly, hand-set `COMPOSE_PROJECT_NAME`, or spawn
   containers outside it — it owns the `PROFILE` export, per-profile subnet
   allocation, and compose-overlay layering. If a capability is missing,
   extend `profile.sh`; never bypass it. (The `justfile` is a thin alias
   layer over it and holds no logic.)
2. **The base compose stays substrate-neutral.** GPU/WSL wiring lives ONLY in
   `docker-compose.wsl-gpu.yml`. Never add devices, host mounts, or
   WSL-specific paths to `docker-compose.yml` — it must come up on bare Linux.
3. **Match existing patterns** in the file you are editing over external
   style guides. Cross-check, but never blind-copy, from the sibling
   `macolima` repo (`docs/sibling-repo-relationship.md`).

## Security-sensitive changes

These files carry the sandbox's guarantees:

- `Dockerfile`
- `docker-compose.yml` **and** `docker-compose.wsl-gpu.yml` (overlay edits add
  devices/mounts without touching the base — same scrutiny)
- `seccomp.json`
- `proxy/squid.conf` + `proxy/allowed_domains.txt`
- `sandbox_templates/claude/claude-settings.json` + `sandbox_templates/claude/hooks/`
- `scripts/profile.sh`, `scripts/init-profile-state.sh`, `scripts/verify-sandbox.sh`
  (the credential.helper scrub both run on every `up` is a load-bearing defense
  against VS Code injecting host-reaching git credential helpers — audit
  Finding B/C in `docs/vscode-integration-security.md`; never remove it as
  "redundant")
- `scripts/run-ephemeral.sh` (raw `docker run` — mirrors compose hardening by hand)
- `scripts/with-egress.sh` — per [ADR-0003](docs/adr/0003-strict-egress-default.md)
  this is the **only** route by which a dependency can enter a profile. It widens
  the allowlist, so a bug here is an egress hole; and it writes the install audit
  log, so a bug here silently *under-reports* — which reads exactly like a clean run.

Any change to them requires:
1. The commit message states the security impact.
2. `scripts/profile.sh <profile> verify` (tier 1) passes; run
   `scripts/profile.sh <profile> audit` (tier 2) for anything non-trivial.
3. Affected docs updated (ARCHITECTURE.md, `sandbox-hardening-package.md`).

Hook edits additionally require
`bash sandbox_templates/claude/hooks/deny-destructive.test.sh` (79/79).
Edits to `scripts/depaudit.py` require `bash scripts/depaudit.test.sh` (26/26
offline; `--online` adds the OSV corpus). Two of its assertions are regression
locks for checks that shipped **inverted** — read the header before changing them.
Edits to `scripts/with-egress.sh` require `bash scripts/with-egress.test.sh`
(38/38, offline — no docker or network). It covers the two parsers, locks a
bracket bug that made a real install log zero egress, and asserts the
container-side allowlist path agrees across all five places it appears.

**`proxy/` is mounted as a DIRECTORY (`./proxy:/etc/squid/host:ro`), and that is
load-bearing.** A single-file bind mount pins an inode at container start, so
`git checkout`/`merge`/`pull`/`stash` — ordinary workflow, not editor quirks —
left running proxies unable to see host edits at all, with `squid -k reconfigure`
re-reading a deleted copy and exiting 0. The allowlist was effectively advisory:
tightening it in git did not take effect. Never revert this to a file mount;
`verify` fails loudly if you do. Changing the mount target means changing the
`acl` in `proxy/squid.conf` and the `PROXY_ALLOWLIST` constant in `profile.sh`,
`with-egress.sh` and `dashboard/src/lib/docker_client.py` — every one of those
fails *silently* on a mismatch, so the test suite locks them together.

## Container state placement

Where a piece of state lives decides whether it survives `docker rm`. The rule:
**if losing it would hurt, it does not live in a container's writable layer.**

| State | Home | Survives `docker rm` |
|---|---|---|
| Source code | host bind mount, in git | yes |
| Python env | `.venv` inside the workspace | yes |
| Models / large data | host dir, gitignored | yes |
| DB data | named volume | yes |
| pip / apt / HF caches | writable layer — disposable by design | no |

A stopped container keeps its whole copy-on-write layer and nothing reports the
cost; six stale VS Code devcontainers reached 149GB here before anyone looked.
`scripts/docker-gc.sh` (`just docker-gc`) sweeps that up — monthly is about
right. It deliberately splits what may be automated from what may not:

- **Auto-prunable**: stopped containers, BuildKit cache. Nothing durable is
  there if the table above is respected.
- **Report-only, human decides**: images and volumes. Volumes are the only
  place durable data lives. And `docker image prune` is *not* safe to automate
  here — pulling a digest-pinned `repo:tag@sha256:...` (as `docker-compose.yml`
  does for postgres/mongo/squid) stores the image with NO tag, so Docker
  classifies it as dangling and an unfiltered prune deletes it. That is why the
  post-build prunes in `scripts/profile.sh` are filtered to the `sandbox.image`
  label set in the `Dockerfile` — never unfilter them.

Never `docker commit` a container as a backup: it captures caches, not data,
and cannot be diffed or restored selectively. Back up the source dir or volume.

## Operational guides (host-agent skills)

- Profile lifecycle, builds, DBs, ephemeral runs, agent-skill seeding:
  [.agents/skills/profile-lifecycle.md](.agents/skills/profile-lifecycle.md)
- Verify / audit / trivy tiers:
  [.agents/skills/security-audit.md](.agents/skills/security-audit.md)
- Egress allowlist edits + with-egress:
  [.agents/skills/squid-management.md](.agents/skills/squid-management.md)

Deep-dive docs are indexed in [docs/index.md](docs/index.md).

## Where things live

Nothing below `docs/` or `work/` is auto-loaded — this index is how it is found.
Before starting work, check `docs/adr/` for decisions constraining the area, and
`work/` for anything already in flight on it.

| The question | Home |
|---|---|
| System map & boundaries | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Why a decision was made | [docs/adr/](docs/adr/) — append-only; supersede, never delete |
| Proposals under discussion | [docs/rfcs/](docs/rfcs/) — `Draft → In review → Accepted → ADR-NNNN \| Rejected` |
| What is in flight right now | [work/](work/) — `NNNN-slug/`, **deleted or archived on merge** |
| Raw unprocessed input | [docs/incoming/](docs/incoming/) — unverified; triage out, don't accumulate |
| Superseded / completed docs | [docs/_archive/](docs/_archive/) |

Tiers adopted 2026-07-31 — [ADR-0001](docs/adr/0001-provenance-tiers.md). A decision
touching the security boundary, persistent data, public contracts, core architecture, or
cross-repo conventions gets an ADR; local implementation details never do.

## Quick reference

```bash
scripts/profile.sh <profile> up|down|attach|verify|audit
scripts/profile.sh list
scripts/profile.sh build --refresh-ai        # bump AI CLIs (tail layer only)
scripts/with-egress.sh <p> --with pypi -- '<cmd>'   # temporary egress widening
scripts/profile.sh <p> deps [--osv]           # dependency posture (host-side, read-only)
scripts/docker-gc.sh --dry-run               # host Docker hygiene (see above)
```

Host state: `~/.ai-sandbox/profiles/<profile>/`; workspace:
`~/repo/<profile>/` → `/workspace`. Rootless socket:
`/run/user/1000/docker.sock`. Container-side root is correct by design
(see ARCHITECTURE.md).

@AGENTS.local.md
