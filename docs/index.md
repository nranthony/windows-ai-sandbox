# Documentation Index

## Architecture & Security

- [CLAUDE.md](../CLAUDE.md) — primary reference for architecture, file layout, security posture, and all common tasks
- [Sandbox design notes](sandbox-design-notes.md) — why rootfs is rw, bwrap is disabled, container runs as root, git config is denied
- [Permissions model](permissions-model.md) — deny/allow posture, two-phase workflow, WebFetch exfil risk, hook self-protection
- [VS Code integration security](vscode-integration-security.md) — SSH agent forwarding, gitconfig leaks, credential helper injection, orphaned root shells
- [Sibling repo: macolima](sibling-repo-relationship.md) — shared vs divergent posture between the two repos, and how to mine the sister repo for flaws we might miss
- [scripts/audit/README.md](../scripts/audit/README.md) — tier-2 structured probe suite (~80 checks, JSON output)
- [seccomp.json](../seccomp.json) — syscall filter (`clone3 → ENOSYS`, `unshare(CLONE_NEWUSER)` blocked)
- [seccomp notes](seccomp-notes.md) — must-keep syscalls, clone3 ENOSYS rule, editing conventions

## Hardening Verification

| Tier | Script | What |
|---|---|---|
| 1 | [`scripts/verify-sandbox.sh`](../scripts/verify-sandbox.sh) | Fast tripwire (~20 pass/fail checks) |
| 2 | [`scripts/audit/`](../scripts/audit/) | ~80 structured probes, JSON output ([README](../scripts/audit/README.md)) |
| 3 | [`config/skills/audit-sandbox/SKILL.md`](../config/skills/audit-sandbox/SKILL.md) | Agent-side judgment over tier-2 JSON (staged into container by `profile.sh audit`) |

## Agent Tool Controls

- [config/claude-settings.json](../config/claude-settings.json) — Bash/Read deny lists (curl, git push, pip install, secrets reads, etc.)
- [deny-destructive hook](deny-destructive-hook-plan.md) — PreToolUse hook blocking destructive commands (find -delete, dd of=, etc.)
- [config/hooks/deny-destructive.sh](../config/hooks/deny-destructive.sh) — hook implementation

## Proxy & Network

- [Squid internals](squid-internals.md) — cap model, tmpfs ownership, port restrictions, hot reload
- [Compose network IPAM](compose-network-ipam.md) — why `down` is needed for IPAM changes, DNS lockdown explained

## GPU & Docker

- [CLAUDE.md](../CLAUDE.md#important-notes) (Important Notes) — NVIDIA Container Toolkit 1.18+ breakage on rootless Docker; why we pin 1.17.8-1
- [sandbox-design-notes.md](sandbox-design-notes.md) — why container runs as root under rootless Docker (UID 0 = host UID 1000)
- [docker-bench-security-report.md](../reports/docker-bench-security-report.md) — Docker Bench for Security v1.6.0 results

## Host Setup

Guides in [`host_setup/`](../host_setup/):

- [setup-rootless-docker-wsl-guide.md](../host_setup/setup-rootless-docker-wsl-guide.md) — rootless Docker on WSL2 Ubuntu 24.04
- [wsl_conf_update-guide.md](../host_setup/wsl_conf_update-guide.md) — /etc/wsl.conf settings
- [wsl_insert-guide.md](../host_setup/wsl_insert-guide.md) — WSL kernel/insert configuration
- [ohmyzsh-host-setup-guide.md](../host_setup/ohmyzsh-host-setup-guide.md) — host-side oh-my-zsh

## CVE Management

- [.trivyignore.yaml](../.trivyignore.yaml) — accepted CVEs/misconfigs with `expired_at` for periodic re-check
- [`scripts/trivy-scan.sh`](../scripts/trivy-scan.sh) — host-side image/config/secret scan

## Scripts Reference

- [`scripts/profile.sh`](../scripts/profile.sh) — profile lifecycle (up, down, attach, auth, verify, audit, rebuild, clean)
- [`scripts/with-egress.sh`](../scripts/with-egress.sh) — temporarily widen Squid allowlist for installs
- [`scripts/run-ephemeral.sh`](../scripts/run-ephemeral.sh) — disposable one-shot containers
- [`scripts/init-profile-state.sh`](../scripts/init-profile-state.sh) — idempotent state bootstrap per profile

## Operational

- [Debug recipes](debug-recipes.md) — routine commands for operating a profile
- [Local wheels](local-wheels.md) — per-profile `dist/` convention for local `.whl` files
- [config/db.env.template](../config/db.env.template) — database credentials template for postgres/mongo sibling containers

## Archive

Superseded or exploratory documents in [`_archive/`](_archive/):

- [PODMAN_MIGRATION_PLAN_gemini.md](_archive/PODMAN_MIGRATION_PLAN_gemini.md) — Podman migration proposal (not proceeding; see critique)
- [PODMAN_MIGRATION_PLAN_critique.md](_archive/PODMAN_MIGRATION_PLAN_critique.md) — analysis of why migration isn't worth it now (security delta ~0.5/10, WSL2 GPU blocker, idmapped mounts as future alternative)
- [gpt_suggestions_todo.md](_archive/gpt_suggestions_todo.md) — early-stage suggestions list
- [claude_internal_audit_wsl.md](_archive/claude_internal_audit_wsl.md) — manual audit prompt, superseded by tier-2 probes + tier-3 skill
