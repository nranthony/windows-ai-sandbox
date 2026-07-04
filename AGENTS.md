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
- `scripts/run-ephemeral.sh` (raw `docker run` — mirrors compose hardening by hand)

Any change to them requires:
1. The commit message states the security impact.
2. `scripts/profile.sh <profile> verify` (tier 1) passes; run
   `scripts/profile.sh <profile> audit` (tier 2) for anything non-trivial.
3. Affected docs updated (ARCHITECTURE.md, `sandbox-hardening-package.md`).

Hook edits additionally require
`bash sandbox_templates/claude/hooks/deny-destructive.test.sh` (35/35).

## Operational guides (host-agent skills)

- Profile lifecycle, builds, DBs, ephemeral runs:
  [.agents/skills/profile-lifecycle.md](.agents/skills/profile-lifecycle.md)
- Verify / audit / trivy tiers:
  [.agents/skills/security-audit.md](.agents/skills/security-audit.md)
- Egress allowlist edits + with-egress:
  [.agents/skills/squid-management.md](.agents/skills/squid-management.md)

Deep-dive docs are indexed in [docs/index.md](docs/index.md).

## Quick reference

```bash
scripts/profile.sh <profile> up|down|attach|verify|audit
scripts/profile.sh list
scripts/profile.sh build --refresh-ai        # bump AI CLIs (tail layer only)
scripts/with-egress.sh <p> --with pypi -- '<cmd>'   # temporary egress widening
```

Host state: `~/.ai-sandbox/profiles/<profile>/`; workspace:
`~/repo/<profile>/` → `/workspace`. Rootless socket:
`/run/user/1000/docker.sock`. Container-side root is correct by design
(see ARCHITECTURE.md).

@AGENTS.local.md
