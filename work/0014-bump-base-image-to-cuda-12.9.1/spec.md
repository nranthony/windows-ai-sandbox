# 0014 — Bump base image to CUDA 12.9.1

**Status:** Not started — captured 2026-08-24, parked until the owner picks the
project up. **The two decisions in §3 are gates: re-verify them against current
state and present them to the owner for sign-off BEFORE implementing anything.**

**Exit rule:** delete this folder, or move to [`docs/_archive/`](../../docs/_archive/),
when the work merges.

---

## 1. Goal

Bump the shared image base from
`nvidia/cuda:12.6.3-base-ubuntu24.04@sha256:c87e78933f4c16e3272123bf2f75537306596d0fbaa395a29696a22786e5ee0e`
(`Dockerfile:19`) to `nvidia/cuda:12.9.1-base-ubuntu24.04`, digest-pinned.

**Rationale:** fresher Ubuntu base packages across the board. The 12.6.3 tag
has not been rebuilt upstream — the registry digest is identical to the pin
already captured — so CVEs living in that base layer (see `.trivyignore.yaml`,
`CVE-2026-45447` / openssl-libssl3) only clear by bumping the tag or by a
targeted in-Dockerfile package upgrade. 12.9.1 stays on the CUDA **12.x** line,
so the PyTorch cu126/cu129 wheel story stays sane — no wheel-index migration
across a major CUDA version.

**Explicitly NOT 13.0.1:** nothing in this repo needs CUDA 13, and the cu130
PyTorch wheel ecosystem is still catching up. Recorded here as a rejected
alternative — see §4 Non-goals.

## 2. Measured facts (2026-08-24)

- Host WSL NVIDIA driver is 610.62, which supports both the 12.9 and 13.0
  CUDA lines (checked against NVIDIA's driver-compatibility table at capture
  time).
- `ARCHITECTURE.md:156` and `README.md:353` currently state the driver floor
  for 12.6.3 as `≥530.30.02` / `≥530.30`. **Not yet looked up:** the driver
  floor for the 12.9.x line — pull it from NVIDIA's CUDA release notes
  compatibility table on pickup and update both lines with the new number.
- `Dockerfile` lines 12–16 document the re-pin procedure to use verbatim:
  ```
  docker pull nvidia/cuda:<new-tag>
  docker inspect --format='{{index .RepoDigests 0}}' nvidia/cuda:<new-tag>
  ```
  paste the `@sha256:...` portion into `Dockerfile:19` (and the header comment
  at `Dockerfile:4`).
- `nvidia-container-toolkit` is pinned separately at `1.17.8-1`
  (`host_setup/setup-rootless-docker-wsl.sh:61`, documented in
  `ARCHITECTURE.md:158` and `docs/index.md:72`) — this is a **host-side**
  toolkit pin, unrelated to the in-container CUDA base version, and is a
  non-goal here (§4).
- Every place that currently names `12.6.3` / `12.6` (from
  `grep -rn "12\.6\.3\|12\.6" --include=*.md --include=Dockerfile --include=*.yml --include=*.toml --include=*.py .`,
  captured 2026-08-24 — re-run on pickup, this list may drift):
  - `Dockerfile:4` — header comment ("Base: NVIDIA CUDA 12.6.3 on Ubuntu 24.04.")
  - `Dockerfile:19` — the `FROM` pin itself
  - `ARCHITECTURE.md:120` — repo-map comment ("Shared image (CUDA 12.6.3 base, ...)")
  - `ARCHITECTURE.md:156` — driver floor line
  - `README.md:133` — base-image table row
  - `README.md:353` — troubleshooting driver-mismatch line
  - `sandbox_templates/common/agent-notice.md:132` — `CUDA_VERSION=12.6.3` in
    the in-container capability notice text (this one is deployed into every
    consumer repo's `AGENTS.md` via `sync-agent-notice.sh` — see AGENTS.md's
    notes on that file; check whether it needs a re-sync after editing, not
    just an in-repo edit)
  - `docs/portability-assessment-plan.md:38` and `:47` — narrative doc,
    update or leave per its own currency (it is a plan doc, not the
    security-sensitive list)
  - `work/0003-repo-scan-audit/plan.md:49` — in-flight work item that also
    names the CUDA constant as something to cross-check; note the bump there
    rather than editing its text out from under it
  - `docs/_archive/*` (`agent_repo_conventions_advice.md`,
    `claude_internal_audit_wsl.md`) — archived narrative, **do not edit**
    per AGENTS.md "Public-repo constraints" (archived record is kept as-is)
  - `container_testing/AGENTS.md` names `cu126` (the PyTorch wheel index), not
    the CUDA base version directly — relevant to D2, not this constant list

## 3. DECISIONS — check, then present to the owner before implementing

**D1 — cu126 torch wheel pins.** Confirm nothing in the workspaces (or in
`container_testing/pyproject.toml` / `container_testing/uv.lock`, which are
visible from here and currently pin the cu126 wheel index per
`container_testing/AGENTS.md`) hard-pins a cu126-specific wheel that would need
re-resolving against a 12.9 runtime. `container_testing`'s pin is checkable
directly on pickup; other workspace `pyproject.toml`/`uv.lock` files outside
this repo's visibility are not — say explicitly that check is deferred to
pickup if a workspace can't be seen.

**D2 — whether to bump the torch wheel index to cu129 in this same item, or
leave it at cu126.** cu126 wheels are commonly claimed to run fine on a 12.9
runtime via CUDA's minor-version forward compatibility. **This is a claim to
VERIFY on pickup** (actually run `torch.cuda.is_available()` and a real tensor
op against the new base with the existing cu126 wheels), not to assume true.
If it holds, leave `container_testing`'s index alone and note the base bump
alone was sufficient; if it doesn't, bumping the index to cu129 becomes
in-scope for this item and needs its own `uv lock` regen per
`container_testing/AGENTS.md`'s host-side lock workflow.

## 4. Steps (after §3 sign-off)

1. Resolve `nvidia/cuda:12.9.1-base-ubuntu24.04`'s current digest and re-pin
   `Dockerfile:19` (and the header comment `Dockerfile:4`) using the
   Dockerfile's own documented procedure (§2, `Dockerfile:12-16`).
2. `just build` — the base layer changes, so this is a full image rebuild;
   `--refresh-ai` alone only bumps the tail AI-CLI layer and will not pick up
   a base swap.
3. Run `container_testing`'s GPU verification on the WSL2 substrate per
   `container_testing/AGENTS.md`'s documented workflow
   (`scripts/profile.sh <profile> exec bash -lc 'cd /workspace/windows-ai-sandbox/container_testing && uv sync --frozen && uv run python -c "import torch; print(torch.cuda.is_available())"'`),
   expect `True`. Resolve D1/D2 as part of this step.
4. Confirm the bare-Linux substrate still comes up with no GPU (base compose
   is substrate-neutral per golden rule 2 — this proves the bump didn't leak
   GPU-only assumptions into the base layer).
5. Update every constant listed in §2's grep results that is in scope
   (security-sensitive + high-visibility surfaces; skip `docs/_archive/` per
   the public-repo constraints). Re-run the grep first — this list may have
   drifted since 2026-08-24.
6. `scripts/profile.sh <profile> verify` (tier 1) and `audit` (tier 2) on a
   live profile; run `scripts/trivy-scan.sh image` and confirm the base-image
   CVE set shrinks, comparing against the `.trivyignore.yaml` baseline
   (entries expiring 2026-08-31, notably `CVE-2026-45447` — the openssl/
   libssl3 entry explicitly says it "clears at the next deliberate base-digest
   bump"; confirm it does, then delete that entry).
7. `just test-offline`.

## 5. Relationship to the interim CVE fix

A targeted `apt-get install --only-upgrade openssl libssl3t64` line is being
added to the Dockerfile separately, same day (2026-08-24), as an interim fix
for `CVE-2026-45447` ahead of this bump. This item supersedes the need for
that line **only if** the new 12.9.1 base tag ships already-fixed
openssl/libssl3 packages — check the installed package versions in the new
base image on pickup, and remove the interim upgrade line if so (leaving it in
alongside a base that already carries the fix is harmless but redundant —
prefer removing it for clarity).

## 6. Security note

`Dockerfile` is on AGENTS.md's security-sensitive list. Required for this
change:
1. Commit message states the security impact (CVE surface shrinks via a
   fresher Ubuntu base; digest re-pinned per the documented procedure).
2. `scripts/profile.sh <profile> verify` (tier 1) passes;
   `scripts/profile.sh <profile> audit` (tier 2) required — this is
   non-trivial (base image swap).
3. `ARCHITECTURE.md` and `sandbox-hardening-package.md` (repo root — there is
   no `docs/` copy) updated to match. Checked 2026-08-24: the hardening doc
   carries no CUDA-version mention, so only the base-digest wording (its
   Finding F) may need touching.

## 7. Non-goals

- CUDA 13 (13.0.1) — see §1's rejected-alternative note.
- Changing the `nvidia-container-toolkit` version pin (`1.17.8-1`, pinned in
  `host_setup/setup-rootless-docker-wsl.sh:61` — a host-side toolkit pin,
  unrelated to the in-container CUDA base version this item bumps).
- Touching the GPU overlay wiring (`docker-compose.wsl-gpu.yml`,
  `/dev/dxg` device mapping) beyond what the version bump itself demands.
