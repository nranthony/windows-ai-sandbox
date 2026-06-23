# Repo Scan — In-Transit Handoff (audit + housekeeping)

> **Status:** planning / not started. Created 2026-06-22 as a follow-up checkpoint.
> Resume by reading this file, then pick a phase below.
> This is a transient working doc — delete or fold into `docs/` once the scan is done.

## Goal

Scan this repo for: inconsistencies, security issues, stale/misaligned docs, and
general logistics / file-keeping. Output should be a findings report + applied
mechanical fixes.

## What this repo is (frames the scan)

Security-critical **infrastructure** repo. 100 tracked files, ~34% markdown (33 `.md`).
Source of truth is **config, not code**: `seccomp.json`, `proxy/squid.conf` +
`allowed_domains.txt`, `docker-compose.yml`, `Dockerfile`, `config/claude-settings.json`.
Tightly coupled to sibling repo **macolima** (referenced in 13 markdown files).

=> Highest-stakes drift is **doc-claims-vs-actual-config** and **this-repo-vs-sibling**,
not code-vs-code.

## Scan dimensions + method

| Dimension | Method |
|---|---|
| Security drift | Cross-check every claim in CLAUDE.md "Security Posture" table + `sandbox-hardening-package.md` against actual compose / seccomp / squid lines |
| Inconsistency | Grep load-bearing constants, confirm one value everywhere: Python ver, CUDA 12.6.3, toolkit `1.17.8-1`, subnet `172.30.x`, ports 8080/8501/8188, `profile.sh` subcommand list |
| Doc staleness | Sort docs by last-commit date vs the code they describe; flag any doc older than its target |
| Misalignment / scope creep | Judge whether workload artifacts belong in a platform repo: `numerai-setup.md`, `docs/therapod-pipeline-db-setup.md`, `dashboard/` |
| Logistics / file-keeping | `git ls-files` for committed build artifacts + root-level sprawl |

## Quick wins already found (Phase 0 — high confidence)

1. **Committed Python bytecode** — 9 `scripts/audit/**/__pycache__/*.pyc` tracked despite
   `.gitignore` having `**.pyc` (gitignore doesn't untrack already-committed files).
   Fix: `git rm -r --cached scripts/audit/**/__pycache__` (verify glob in zsh).
2. **Version inconsistency** — those `.pyc` are `cpython-314` (Python 3.14) but CLAUDE.md
   states default venv is **Python 3.12**. Resolve: which interpreter actually runs the
   audit probes? Bytecode may just be stale (another reason to untrack it).
3. **Root-level doc sprawl** — `numerai-setup.md`, `agent_repo_conventions_advice.md`,
   `SECURITY_ASSESSMENT.md`, `sandbox-hardening-package.md` at top level while `docs/`
   (with `index.md`) exists. Decide canonical home; move the rest under `docs/`.
4. **Two parallel archive zones** — `archived_script_ref/` and `docs/_archive/`
   (incl. `gpt_suggestions_todo.md`, `PODMAN_MIGRATION_PLAN_*`). Keep but fence off so a
   scan doesn't treat them as current.
5. **Secret check** — `config/db.env.template` is the only secret-shaped tracked file;
   confirm it's a pure template (no real values). `.env` is gitignored (good).

## Staleness signal (already observed)

- `host_setup/*-guide.md` and `reports/docker-bench-security-report.md` frozen at
  **2025-06-23** while their scripts moved in **2026-06**. Prime staleness suspects.

## Phased approach

- **Phase 0 — mechanical (minutes):** apply quick wins 1–5 above.
- **Phase 1 — config-truth audit (the valuable part):** verify every security claim in
  CLAUDE.md / `sandbox-hardening-package.md` against actual config. Verify adversarially.
- **Phase 2 — doc staleness sweep:** each `.md` vs the code it describes; flag, don't blind-rewrite.
- **Phase 3 — sibling-repo alignment:** reconcile the 13 macolima refs (CLAUDE.md warns
  "do not blind-copy" — known live risk).

Phases 1–3 are independent and parallel — candidate for a multi-agent **workflow**
(fan out config-audit / doc-staleness / alignment, then adversarially verify). Run inline
unless scale is explicitly requested.

## Decision still open

Chosen execution mode (full inline audit / Phase 1 only / quick wins only / workflow) —
**not yet selected.** Pick one when resuming.
