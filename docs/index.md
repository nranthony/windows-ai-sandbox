# Documentation Index

## Provenance tiers

Adopted 2026-07-31 ([ADR-0001](adr/0001-provenance-tiers.md)). The chain reads left to
right: an **RFC** proposes → an **ADR** records → **work/** implements → the commit
(citing the ADR) is the outcome.

- [docs/adr/](adr/) — decisions and their rationale. Append-only.
  - [ADR-0001](adr/0001-provenance-tiers.md) — adopt these tiers
  - [ADR-0002](adr/0002-dependency-guardrail-scope.md) — dependency guardrails: what we deliberately do not build (Proposed)
- [docs/rfcs/](rfcs/) — proposals under discussion ([TEMPLATE.md](rfcs/TEMPLATE.md))
  - [DEPENDENCY_GUARDRAILS.md](rfcs/DEPENDENCY_GUARDRAILS.md) — slopsquatting threat + agent behavioural rules
  - [01-posture-scanner-plan.md](rfcs/01-posture-scanner-plan.md) — `depaudit`, stdlib-only dependency posture/inventory scanner
  - [02-layered-gates-plan.md](rfcs/02-layered-gates-plan.md) — `depgate`, five-gate model (largely declined here)
  - [04-portable-guardrails-outside-sandbox.md](rfcs/04-portable-guardrails-outside-sandbox.md) — what applies on the host, outside the egress boundary
- [work/](../work/) — in-flight items, deleted or archived on merge ([README](../work/README.md))
  - [0001-dependency-guardrails](../work/0001-dependency-guardrails/plan.md) — applying the above to this repo
  - [0002-host-side-skill-slot](../work/0002-host-side-skill-slot/plan.md) — `make-plan`/`wrap-up` are container-only
  - [0003-repo-scan-audit](../work/0003-repo-scan-audit/plan.md) — audit + housekeeping scan
- [docs/incoming/](incoming/) — raw unprocessed input, **unverified** ([README](incoming/README.md))

## Architecture & Security

- [AGENTS.md](../AGENTS.md) — agent conventions: golden rules, security-sensitive files, verification protocol (CLAUDE.md is a generated pointer to it)
- [ARCHITECTURE.md](../ARCHITECTURE.md) — system map: substrates, network model, state layout, security posture, repo map
- [.agents/skills/](../.agents/skills/) — operational guides: profile lifecycle, audit tiers, squid allowlist
- [Sandbox design notes](sandbox-design-notes.md) — why rootfs is rw, bwrap is disabled, container runs as root, git config is denied
- [Permissions model](permissions-model.md) — deny/allow posture, two-phase workflow, WebFetch exfil risk, hook self-protection
- [VS Code integration security](vscode-integration-security.md) — SSH agent forwarding, gitconfig leaks, credential helper injection, orphaned root shells
- [Sibling repo: macolima](sibling-repo-relationship.md) — shared vs divergent posture between the two repos, and how to mine the sister repo for flaws we might miss
- [Portability assessment + plan](portability-assessment-plan.md) — running on bare-Ubuntu rootless (validated 2026-07-04, incl. GPU-overlay auto-detect design) and why rootful Docker is a redesign, not a toggle
- [scripts/audit/README.md](../scripts/audit/README.md) — tier-2 structured probe suite (~80 checks, JSON output)
- [seccomp.json](../seccomp.json) — syscall filter (`clone3 → ENOSYS`, `unshare(CLONE_NEWUSER)` blocked)
- [seccomp notes](seccomp-notes.md) — must-keep syscalls, clone3 ENOSYS rule, editing conventions

## Hardening Verification

| Tier | Script | What |
|---|---|---|
| 1 | [`scripts/verify-sandbox.sh`](../scripts/verify-sandbox.sh) | Fast tripwire (~57 pass/fail/warn outcomes across ~28 checks) |
| 2 | [`scripts/audit/`](../scripts/audit/) | ~80 structured probes, JSON output ([README](../scripts/audit/README.md)) |
| — | [`scripts/depaudit.test.sh`](../scripts/depaudit.test.sh) | depaudit regression suite (26 offline, `--online` adds the OSV corpus) over [fixtures](../scripts/depaudit-fixtures/) |
| 3 | [`sandbox_templates/skills/audit-sandbox/SKILL.md`](../sandbox_templates/skills/audit-sandbox/SKILL.md) | Agent-side judgment over tier-2 JSON (staged into container by `profile.sh audit`) |

## Agent Tool Controls

- [sandbox_templates/claude/claude-settings.json](../sandbox_templates/claude/claude-settings.json) — Bash/Read deny lists (curl, git push, pip install, secrets reads, etc.)
- [deny-destructive hook](deny-destructive-hook-plan.md) — PreToolUse hook blocking destructive commands (find -delete, dd of=, etc.)
- [sandbox_templates/claude/hooks/deny-destructive.sh](../sandbox_templates/claude/hooks/deny-destructive.sh) — hook implementation

## Proxy & Network

- [Squid internals](squid-internals.md) — cap model, tmpfs ownership, port restrictions, hot reload
- [Compose network IPAM](compose-network-ipam.md) — why `down` is needed for IPAM changes, DNS lockdown explained
- [Web-read broker (`webfetch`)](web-read-broker.md) — how the agent reads arbitrary pages through an allowlisted reader API (Tavily/Jina/Firecrawl) without widening egress

## GPU & Docker

- [ARCHITECTURE.md](../ARCHITECTURE.md) (Substrate-specific notes) — NVIDIA Container Toolkit 1.18+ breakage on rootless Docker; why we pin 1.17.8-1; wsl-gpu overlay
- [sandbox-design-notes.md](sandbox-design-notes.md) — why container runs as root under rootless Docker (UID 0 = host UID 1000)
- [docker-bench-security-report.md](../reports/docker-bench-security-report.md) — Docker Bench for Security v1.6.0 results

## Host Setup

Guides in [`host_setup/`](../host_setup/):

- [setup-rootless-docker-wsl-guide.md](../host_setup/setup-rootless-docker-wsl-guide.md) — rootless Docker on WSL2 Ubuntu 24.04
- [wsl_conf_update-guide.md](../host_setup/wsl_conf_update-guide.md) — /etc/wsl.conf settings
- [wsl_insert-guide.md](../host_setup/wsl_insert-guide.md) — /etc/wsl.conf insert settings (automount, network, interop)
- [ohmyzsh-host-setup-guide.md](../host_setup/ohmyzsh-host-setup-guide.md) — host-side oh-my-zsh

## CVE Management

- [.trivyignore.yaml](../.trivyignore.yaml) — accepted CVEs/misconfigs with `expired_at` for periodic re-check
- [`scripts/trivy-scan.sh`](../scripts/trivy-scan.sh) — host-side image/config/secret scan

## Scripts Reference

- [`scripts/profile.sh`](../scripts/profile.sh) — profile lifecycle (up, down, attach, auth, verify, audit, rebuild, clean)
- [`scripts/with-egress.sh`](../scripts/with-egress.sh) — temporarily widen Squid allowlist for installs
- [`scripts/depaudit.py`](../scripts/depaudit.py) — dependency-supply-chain posture scanner (stdlib-only, read-only; `posture` is offline, `pkg`/`deps` cross-check OSV for malicious-package records). Surfaced as `scripts/profile.sh <p> deps`
- [`scripts/run-ephemeral.sh`](../scripts/run-ephemeral.sh) — disposable one-shot containers
- [`scripts/init-profile-state.sh`](../scripts/init-profile-state.sh) — idempotent state bootstrap per profile
- [`scripts/sync-agent-notice.sh`](../scripts/sync-agent-notice.sh) — inject/refresh the managed sandbox-notice block into repo `AGENTS.md` / global `CLAUDE.md` (source: `sandbox_templates/common/agent-notice.md`)
- [`scripts/sync-skills-from-conventions.sh`](../scripts/sync-skills-from-conventions.sh) — vendor shared skills from the `agentic-conventions` checkout into `sandbox_templates/skills/` (developer action, never runs during a build; source path from `$CONVENTIONS_DIR` / `.conventions-dir.local`)

## Operational

- [Debug recipes](debug-recipes.md) — routine commands for operating a profile
- [Local wheels](local-wheels.md) — per-profile `dist/` convention for local `.whl` files
- [sandbox_templates/common/db.env.template](../sandbox_templates/common/db.env.template) — database credentials template for postgres/mongo sibling containers

## Archive

Superseded or exploratory documents in [`_archive/`](_archive/):

- [PODMAN_MIGRATION_PLAN_gemini.md](_archive/PODMAN_MIGRATION_PLAN_gemini.md) — Podman migration proposal (not proceeding; see critique)
- [PODMAN_MIGRATION_PLAN_critique.md](_archive/PODMAN_MIGRATION_PLAN_critique.md) — analysis of why migration isn't worth it now (security delta ~0.5/10, WSL2 GPU blocker, idmapped mounts as future alternative)
- [gpt_suggestions_todo.md](_archive/gpt_suggestions_todo.md) — early-stage suggestions list
- [claude_internal_audit_wsl.md](_archive/claude_internal_audit_wsl.md) — manual audit prompt, superseded by tier-2 probes + tier-3 skill
- [agent_repo_conventions_advice.md](_archive/agent_repo_conventions_advice.md) — agent-native repo conventions proposal, implemented 2026-07-04 (AGENTS.md, .agents/skills/, sandbox_templates/)
- [IN_TRANSIT_agent-native-migration.md](_archive/IN_TRANSIT_agent-native-migration.md) — execution plan distilled from the above; all 8 steps landed 2026-07-04, archived from the repo root 2026-07-31
