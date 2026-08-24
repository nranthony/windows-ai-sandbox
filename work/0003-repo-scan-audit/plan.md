# Repo Scan — audit + housekeeping

> **Status:** planning / not started. Created 2026-06-22 as a follow-up checkpoint;
> migrated from root `REPO-SCAN_in-transit_audit-and-housekeeping.md` into the `work/`
> tier on 2026-07-31 ([ADR-0001](../../docs/adr/0001-provenance-tiers.md)).
> Resume by reading this file, then pick a phase below.
>
> **Exit rule:** this folder is deleted, or moved to `work/archive/`, when the scan
> completes — replacing the hand-rolled "delete or fold into `docs/`" note it carried
> as a root-level file.
>
> **Note (2026-07-31):** quick win 3 (root-level doc sprawl) is now partly addressed —
> the two in-transit root docs it names are gone, and `numerai-setup.md`,
> `SECURITY_ASSESSMENT.md`, `sandbox-hardening-package.md` remain open questions.
>
> **Status note, refreshed 2026-08-24, shelved; execute after the branch merges.**
> (0011's convergence work — the thing this item was previously held for — has
> since landed on `feat/0010-antigravity-guardrails`; the remaining hold is the
> branch merge itself, not a wait on 0011.) See the corrections folded in below
> (source: `docs/incoming/2026-08-24-work-item-audit-corrections.md` §0003); a
> few counts were re-verified again at fold time and differ slightly from that
> list, noted inline.

## Goal

Scan this repo for: inconsistencies, security issues, stale/misaligned docs, and
general logistics / file-keeping. Output should be a findings report + applied
mechanical fixes.

## What this repo is (frames the scan)

Security-critical **infrastructure** repo. 222 tracked files, ~44.6% markdown
(99 `.md`) as of 2026-08-24 (re-verified at fold time: 226 files / 101 `.md`,
still ~44.7% — re-count again at execution time, this keeps moving). At this
size the deferred workflow/fan-out execution mode (see "Decision still open"
below) is the more defensible default for Phases 1–3, not just a candidate.
Source of truth is **config, not code**: `seccomp.json`, `proxy/squid.conf` +
`allowed_domains.txt`, `docker-compose.yml`, `Dockerfile`, `sandbox_templates/claude/claude-settings.json`.
Tightly coupled to sibling repo **macolima** (referenced in 13 markdown files).

=> Highest-stakes drift is **doc-claims-vs-actual-config** and **this-repo-vs-sibling**,
not code-vs-code.

## Scan dimensions + method

| Dimension | Method |
|---|---|
| Security drift | Cross-check every claim in ARCHITECTURE.md's "## Security posture" section (`ARCHITECTURE.md:88`, confirmed still current at `:93` on re-check) — NOT CLAUDE.md, which is now a 5-line generated pointer — against actual compose / seccomp / squid lines. The table has since grown rows for agy tools (ADR-0006), Dependencies (ADR-0003/0004), and Vendored tools (ADR-0014); verify those too |
| Inconsistency | Grep load-bearing constants, confirm one value everywhere: Python ver, CUDA 12.6.3, toolkit `1.17.8-1`, subnet `172.30.x`, `profile.sh` subcommand list, and (see Constants row below) 8080/8501/8188/3128/`SANDBOX_OCTET` |
| Doc staleness | Sort docs by last-commit date vs the code they describe; flag any doc older than its target |
| Misalignment / scope creep | Judge whether workload artifacts belong in a platform repo: `numerai-setup.md`, `docs/therapod-pipeline-db-setup.md`, `dashboard/` |
| Logistics / file-keeping | `git ls-files` for committed build artifacts + root-level sprawl |

## Quick wins already found (Phase 0 — high confidence)

~~1. **Committed Python bytecode** — DONE 2026-07-04.~~
~~2. **Version inconsistency** — MOOT: no `.pyc` artifact remains tracked;
   current state is self-consistent at Python 3.12.~~
3. **Root-level doc sprawl** — `SECURITY_ASSESSMENT.md`, `sandbox-hardening-package.md`
   at top level while `docs/` (with `index.md`) exists. Decide canonical home; move the
   rest under `docs/`. (The `numerai-setup.md` third of this win is DONE — the tracked
   file was deleted in `6591e5a`; `git ls-files numerai-setup.md` is empty. An untracked
   copy of the same filename still sits on disk locally as of 2026-08-24 — not repo
   state, ignore it, but don't let it read as evidence the deletion didn't happen.)
   (`agent_repo_conventions_advice.md`: DONE 2026-07-04 — implemented and archived to
   `docs/_archive/`.)
4. **Two parallel archive zones** — `archived_script_ref/` and `docs/_archive/`
   (incl. `gpt_suggestions_todo.md`, `PODMAN_MIGRATION_PLAN_*`). Keep but fence off so a
   scan doesn't treat them as current. **`docs/_archive/` still has no fencing** as of
   2026-08-24 (no README, no skip-list entry) — unlike `archived_script_ref/`, which
   `scripts/trivy-scan.sh:64` already `--skip-dirs`s and ARCHITECTURE.md:149 labels
   "Deprecated material (do not treat as current)". This is the concrete Phase 0 action
   the "fence off" language above was gesturing at and never did.
5. **Secret check** — factual correction: there are now TWO secret-shaped tracked
   templates. `sandbox_templates/common/db.env.template` (moved from `config/`; its own
   header comment still says `cp config/…`, which is itself stale and worth a one-line
   fix) and `sandbox_templates/common/secrets.env.template` (verified clean). Confirm
   both are pure templates (no real values) — spot-checked 2026-08-24, both clean.
   `.env` is gitignored (good).

## Constants row (Inconsistency dimension)

Re-grep before Phase 1: 8080/8501/8188 are **devcontainer forwarding ports**, not
sandbox constants — zero hits in `docker-compose.yml` or `docker-compose.wsl-gpu.yml`
(confirmed 2026-08-24). Add to the constants-to-check list: `3128` (Squid's port —
`proxy/squid.conf:9`, `docker-compose.yml:92-95`) and `SANDBOX_OCTET` (per-profile
subnet octet — `scripts/profile.sh`, `scripts/setup.sh`).

## Staleness signal (already observed)

- Of the four `host_setup/*-guide.md` files, three plus
  `reports/docker-bench-security-report.md` are frozen at **2025-06-23** (14 months as
  of 2026-08-24) while their scripts moved in **2026-06** — prime staleness suspects.
  `host_setup/setup-rootless-docker-wsl-guide.md` is NOT one of them — it was refreshed
  2026-07-04 (confirmed via `git log`) and should be dropped from the suspect list.
- **`SECURITY_ASSESSMENT.md`** (root, dated 2026-05-28, "Gemini CLI"-authored, indexed
  nowhere in `docs/index.md`, predates every major effort since) is the highest-value
  Phase 2 target — confirmed still present at root as of 2026-08-24.

## Phased approach

- **Phase 0 — mechanical (minutes):** apply quick wins 1–5 above.
- **Phase 1 — config-truth audit (the valuable part):** verify every security claim in
  CLAUDE.md / `sandbox-hardening-package.md` against actual config. Verify adversarially.
- **Phase 2 — doc staleness sweep:** each `.md` vs the code it describes; flag, don't blind-rewrite.
- **Phase 3 — sibling-repo alignment:** reconcile the 13 macolima refs (CLAUDE.md warns
  "do not blind-copy" — known live risk). **Collides with the pending macolima Mac
  verification** (commit `1b8158f`, tracked in memory as
  `macolima-agy-pnpm-port-pending-mac-verify`) — that verification changes sibling-repo
  state this phase would be reconciling against, so sequence Phase 3 after it lands, or
  re-scope Phase 3's findings once it does.

Phases 1–3 are independent and parallel — candidate for a multi-agent **workflow**
(fan out config-audit / doc-staleness / alignment, then adversarially verify). Run inline
unless scale is explicitly requested.

**Offline test suites now cover a slice of Phase 1 mechanically.** AGENTS.md states
"`just test-offline` runs all nine suites" (verified 2026-08-24 against AGENTS.md and
`justfile`'s `test-offline` recipe — the count is nine, not the "eight-plus" this note
originally estimated). Whatever those nine suites already lock (hook parity, antigravity
parity, with-egress parsing, dockerfile ordering, skills convergence, vendor-tools,
agent-notice, depaudit, dep-audit variants) does not need hand-verification in Phase 1 —
scope Phase 1's manual cross-checking to what the suites don't cover.

## Decision still open

Chosen execution mode (full inline audit / Phase 1 only / quick wins only / workflow) —
**not yet selected.** Pick one when resuming.
