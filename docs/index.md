# Documentation Index

## Architecture & Security

- [CLAUDE.md](../CLAUDE.md) — primary reference for architecture, file layout, security posture, and all common tasks
- [VS Code integration security](vscode-integration-security.md) — SSH agent forwarding, gitconfig leaks, credential helper injection, orphaned root shells; required host settings and operational guardrails
- [scripts/audit/README.md](../scripts/audit/README.md) — tier-2 structured probe suite (~80 checks, JSON output)
- [seccomp.json](../seccomp.json) — syscall filter (`clone3 → ENOSYS`, `unshare(CLONE_NEWUSER)` blocked)

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

## GPU & Docker

- [GPU-FIX-MIGRATION.md](../.devcontainer/GPU-FIX-MIGRATION.md) — NVIDIA Container Toolkit 1.18+ breakage on rootless Docker; why we pin 1.17.8-1
- [ROOTLESS-DOCKER-NOTES.md](../.devcontainer/ROOTLESS-DOCKER-NOTES.md) — why container runs as root under rootless Docker (UID 0 = host UID 1000)
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

## Archive

Superseded or exploratory documents in [`_archive/`](_archive/):

- [PODMAN_MIGRATION_PLAN_gemini.md](_archive/PODMAN_MIGRATION_PLAN_gemini.md) — Podman migration proposal (not proceeding; see critique)
- [PODMAN_MIGRATION_PLAN_critique.md](_archive/PODMAN_MIGRATION_PLAN_critique.md) — analysis of why migration isn't worth it now (security delta ~0.5/10, WSL2 GPU blocker, idmapped mounts as future alternative)
- [gpt_suggestions_todo.md](_archive/gpt_suggestions_todo.md) — early-stage suggestions list
- [claude_internal_audit_wsl.md](_archive/claude_internal_audit_wsl.md) — manual audit prompt, superseded by tier-2 probes + tier-3 skill
