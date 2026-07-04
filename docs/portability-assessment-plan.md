# Multi-Substrate Portability — Assessment & Plan

> **Status:** IMPLEMENTED 2026-07-04 (branch `portability-and-agent-conventions`) — §A2 design
> landed as written: `docker-compose.wsl-gpu.yml` overlay + `/dev/dxg` auto-detect (`SANDBOX_GPU`
> override) in `profile.sh`/`run-ephemeral.sh`, NVIDIA gating in host setup, substrate-aware
> verifier (uid_map `0 0` hard-fails; GPU checks N/A off-WSL). §A3 conventions migration also
> landed (AGENTS.md / ARCHITECTURE.md / .agents/skills/ / sandbox_templates/). Kept for the
> rootful analysis (§3) and still-open items (§A4).
> Original: DRAFT 2026-06-30, assessment only. **ADDENDUM 2026-07-04** at bottom of file.
> **Scope:** Can this sandbox stand up cleanly on substrates *other* than "WSL2 + rootless Docker + NVIDIA"?
> Specifically: (1) **rootless Docker on bare Ubuntu Linux, no NVIDIA**; (2) **standard (rootful) Docker with equivalent security** (closer to a cloud / Linux-workstation deployment).
> **Decision owner:** repo maintainer (will cross-check + implement later). This doc is the design artifact to argue against before code is touched.

---

## 0. TL;DR

| Scenario | Fluidity | One-line verdict |
|---|---|---|
| **1. Rootless Docker, bare Ubuntu, no NVIDIA** | **~85%** | Security ports with **zero regression**. Only mechanical decoupling needed; **one hard blocker** (`/dev/dxg`). |
| **2. Rootful Docker, "same security"** | **~40%** | Boots, but the **core security guarantee is lost by default**. Recovering it is a privilege-model **redesign**, not a config toggle. The honest cloud answer is *don't use rootful* — use rootless / Podman / gVisor. |

The load-bearing fact behind both numbers: **the headline guarantee (a full container escape yields only an unprivileged host account) rests on rootless Docker's `userns=host` mapping — container UID 0 ↔ host UID 1000. That mapping is a property of *rootless Docker*, not of WSL.** It therefore ports for free to bare-Ubuntu rootless (Scenario 1) and is *absent* under rootful Docker (Scenario 2).

---

## 1. Evidence — where WSL / NVIDIA / rootless are actually wired in

Mechanisms split cleanly into substrate-agnostic (port anywhere unchanged) vs substrate-coupled (need change):

| Mechanism | Coupled to | File / location | Behaviour off-substrate |
|---|---|---|---|
| cap_drop:ALL, seccomp, no-new-privileges, tmpfs noexec | nothing | `docker-compose.yml`, `seccomp.json` | ports 1:1 |
| `sandbox-internal` `internal:true` + Squid + DNS sinkhole + `extra_hosts` | nothing | `docker-compose.yml`, `proxy/` | ports 1:1 |
| **container UID 0 ↔ host UID 1000** | **rootless Docker** | implicit; asserted by verifier | identical on bare-Ubuntu rootless; **gone** under rootful |
| `/dev/dxg` device passthrough | WSL **and** NVIDIA | `docker-compose.yml` `devices:` | **HARD FAIL** — Docker errors on missing device node |
| `/usr/lib/wsl` mount + `LD_LIBRARY_PATH=/usr/lib/wsl/lib` | WSL + NVIDIA | `docker-compose.yml` `volumes:`/`environment:` | dead but not fatal (rootless dockerd auto-creates empty source dir) |
| CUDA base image | NVIDIA | `Dockerfile` `FROM nvidia/cuda:12.6.3-base-ubuntu24.04` | runs without GPU; just heavy + more CVEs |
| D-Bus kickstart block | WSL | `host_setup/setup-rootless-docker-wsl.sh` (~L150) | **self-guards** on `$WSL_DISTRO_NAME` → no-op on bare Ubuntu |
| nvidia-container-toolkit install + `nvidia-ctk runtime configure` / `--no-cgroups` | NVIDIA | `host_setup/setup-rootless-docker-wsl.sh` (~L12–41, L187–197) | ~15 lines; must be skipped sans-GPU |
| `verify-sandbox.sh` `uid_map == "0 1000 1"` assert | rootless | `scripts/verify-sandbox.sh` (~L34) | **passes** on bare-Ubuntu rootless; **fails** under rootful (correct canary) |
| `verify-sandbox.sh` `/dev/dxg`, `/usr/lib/wsl/lib` checks | WSL | `scripts/verify-sandbox.sh` (~L129–130) | already **warn-only**, not fail |
| rootless toolchain, `loginctl enable-linger`, systemd-user `docker.service`, hardened `daemon.json` | systemd (not WSL) | `host_setup/setup-rootless-docker-wsl.sh` | correct for bare Ubuntu as-is |

**Verified facts (this device):**
- Compose hard-codes `devices: - /dev/dxg` and `volumes: - /usr/lib/wsl:/usr/lib/wsl:ro`.
- `Dockerfile` base is `nvidia/cuda:12.6.3-base-ubuntu24.04` (digest-pinned).
- The D-Bus kickstart in the setup script is wrapped in `if [ -n "$WSL_DISTRO_NAME" ]` — it disables itself off-WSL.
- `verify-sandbox.sh` hard-asserts the rootless uid_map but only `warn`s on the WSL GPU paths.
- `profile.sh` contains **no** GPU/WSL guard (`grep dxg|wsl|gpu` → empty) — the coupling lives entirely in compose + Dockerfile + setup script.

---

## 2. Scenario 1 — Rootless Docker, bare Ubuntu, no NVIDIA — **~85% fluid**

### Why it ports cleanly
- The UID 0→1000 remap is intrinsic to rootless Docker → **same boundary on bare Ubuntu**.
- Entire hardening stack (caps, seccomp, no-new-privileges, internal net, DNS sinkhole, Squid, tmpfs) is substrate-agnostic.
- Bare Ubuntu is in several ways *simpler* than WSL: native persistent systemd (no `wsl --shutdown` cycle), no `.wslconfig` / `wsl.conf`, no mirrored-networking quirk, D-Bus race block self-disables.

### Blockers (all mechanical, no security thinking required)
1. **Hard blocker:** remove/guard `devices: - /dev/dxg` — the *only* thing that prevents the stack coming up.
2. Remove the `/usr/lib/wsl` mount + `LD_LIBRARY_PATH` (dead weight, not fatal).
3. Skip the NVIDIA toolkit install + `nvidia-ctk` config in the setup script (~15 lines).
4. *(Optional)* swap CUDA base → `ubuntu:24.04` to cut image size + CVE surface.
5. `verify-sandbox.sh` already warn-only on dxg/wsl; uid_map assert still passes. No security check regresses.

**Estimate:** ~half a day of parameterization. No security regression.

---

## 3. Scenario 2 — Rootful Docker, "same security" — **~40% fluid (redesign, not config)**

### The problem
The compose will *boot* under rootful (minus `/dev/dxg`), but **container UID 0 = host UID 0 (real root)**. The headline guarantee collapses: a container escape or a malicious bind-mount write now lands as host root. cap_drop + seccomp + no-new-privileges still shrink blast radius, but the boundary the whole design advertises is gone. `verify-sandbox.sh`'s `uid_map == "0 1000 1"` assert **fails** here — correctly.

### Recovering equivalence requires a privilege-model change (both options non-trivial)
- **(a) daemon-wide `userns-remap`** (`/etc/docker/daemon.json`). Closest equivalent (reintroduces a 0→high-UID remap). **But breaks every bind mount:** workspace + `~/.ai-sandbox` state are host-UID-1000-owned; remap base is 100000+, so the container can't write them — the exact failure `CLAUDE.md` warns about. Requires chowning all bind-mounted state to the remapped base and rewriting the 0→1000 assumptions repo-wide.
- **(b) run container as non-root** (`user: 1000:1000`). Image is root-homed (`/root/.claude`, tmpfs `/root/.*`); requires rehoming to `/home/<uid>` + rebuild.

Both also require rewriting the verifier's mapping assertion and reversing the "root-in-container is correct" docs. Rootful additionally re-introduces the root-owned daemon + socket that rootless deliberately removes — a *worse* posture on a shared host, not better.

### Honest recommendation for cloud / workstation
**Do not retrofit rootful.** The model wants a UID-remapping runtime; several preserve it nearly for free:
- **Rootless Docker on the cloud VM** = Scenario 1, the cheap path.
- **Podman rootless** — near drop-in.
- **gVisor `runsc` / Sysbox** — defense-in-depth on top.

Rootful-Docker-with-bolt-ons is the *most expensive* way to get back what rootless gives out of the box.

---

## 4. Recommendations (ordered; for implementation later)

> Carries forward the three from the earlier from-scratch review (NEW-DEVICE checklist, `db-postgres` footgun, data-fixture provisioning) — portability reorders priority above them.

1. **Decouple GPU/WSL from compose (highest leverage).** Move `/dev/dxg`, the `/usr/lib/wsl` mount, and `LD_LIBRARY_PATH` into a `docker-compose.gpu.yml` override (or env-gate). `profile.sh` conditionally adds `-f docker-compose.gpu.yml` when a GPU is detected. Unblocks Scenario 1 entirely; hardening untouched.
2. **Make NVIDIA optional in the host setup script.** Guard the toolkit install + `nvidia-ctk` behind `command -v nvidia-smi` or a `--no-gpu` flag; rename WSL-specific sudoers/comments. D-Bus block already self-guards, so bare-Ubuntu support is mostly subtraction.
3. **Add a `BASE_IMAGE` build arg** so sans-GPU hosts build on `ubuntu:24.04` (smaller, fewer CVEs) instead of the CUDA base.
4. **Generalize `verify-sandbox.sh`** to detect runtime and assert the *right* boundary: `0 1000 1` for rootless, `0 <baseuid>` for userns-remap, **hard-fail** on `0 0` (rootful unremapped) instead of silently passing other checks. Make dxg/wsl checks "N/A on non-WSL," not warn.
5. **Write `docs/deployment-substrates.md`** stating plainly: *the security model requires a UID-remapping runtime.* Recommend rootless / Podman / gVisor for cloud; document the rootful + userns-remap + bind-mount-chown path only as a discouraged fallback with caveats.
6. **Substrate-branched NEW-DEVICE checklist** with two clean arms (WSL+GPU / bare-Linux rootless) + an explicit "rootful is a redesign" warning — instead of one WSL-shaped happy path.

### Carried-forward (from from-scratch review, still valid)
- **A. `docs/NEW-DEVICE.md`** — one ordered checklist chaining Windows/Linux base → host_setup → clone repos + stage data → `.env` → build → profile up → `db.env` from template → `COMPOSE_PROFILES=db-postgres up` → DB steps. Mostly links to existing docs. (Now branches per substrate per #6.)
- **B. Close the `db-postgres` footgun** — `COMPOSE_PROFILES` appears **nowhere** in `profile.sh`; a plain `up` brings up agent+proxy **without Postgres**, so the pipeline API crash-loops on its asyncpg pool. Implement the per-profile `compose-profiles` file the DB doc already designed (mirroring `subnet-octet`) so `up` is zero-prefix.
- **C. Document the therapod data fixtures** — the pipeline repo + H10 raw_data parquet (`raw_data/.../polar_h10_ecg_parquet/P01..P24_ECG.parquet`) are separate repos / large data referenced as pre-existing; no doc tells a new operator to fetch them.

---

## 5. Open questions for reviewers

1. **Override vs. profiles vs. env-gate** for the GPU decoupling (#1) — which is least surprising for `profile.sh` and the `justfile` pass-throughs? (`-f` layering changes the `docker compose` invocation in several places.)
2. Is a **second base image** (#3) worth the build-matrix cost, or is "CUDA base everywhere, GPU optional at runtime" acceptable for bare-Ubuntu hosts?
3. For cloud: is **Podman rootless** in-scope as a first-class target, or do we standardize on rootless Docker only and treat Podman as community-supported?
4. Should `verify-sandbox.sh` **hard-fail** on `0 0` (#4), or warn — i.e. do we ever want to *intentionally* run rootful for a throwaway dev box without the verifier screaming?
5. Headless cloud auth: `claude login` / `gh auth login` are browser-interactive — do we need a documented device-code / token path for non-desktop hosts? (Minor, but blocks true headless bring-up.)

---

## 6. Non-goals / explicitly out of scope
- Actually implementing any of the above (maintainer will cross-check + implement).
- Windows-side provisioning gaps (covered in the prior from-scratch review).
- macolima parity — the sibling repo is a separate cross-check; do not blind-copy (see `docs/sibling-repo-relationship.md`).

---

# ADDENDUM (2026-07-04) — Validated on a live bare-Ubuntu host + concrete implementation design

> Scenario 1 is no longer hypothetical: this repo is now checked out on a **bare Ubuntu 24.04.4
> host** (kernel `6.17.0-35-generic`, `WSL_DISTRO_NAME` unset, no `/dev/dxg`, no `/usr/lib/wsl`,
> no `nvidia-smi`) with **rootless Docker already installed and running** (`name=rootless` in
> `docker info`, socket at `/run/user/1000/docker.sock`). `host_setup/` does not need to run here.
> Everything below was verified against the actual files on 2026-07-04.

## A1. Validation results — §1 evidence table confirmed, one gap found

- The compose coupling is exactly as stated: `devices: - /dev/dxg` (`docker-compose.yml:30`,
  the sole hard blocker), `/usr/lib/wsl` mount (`:60`), `LD_LIBRARY_PATH=/usr/lib/wsl/lib` (`:77`).
- `verify-sandbox.sh:129-130` GPU checks are warn-only as stated; the `uid_map == "0 1000 1"`
  assert passes unchanged on this host's rootless daemon.
- **GAP (missed by §1):** `scripts/run-ephemeral.sh` is a fourth coupling site — it hard-codes
  `--device /dev/dxg` (`:66`), `-e LD_LIBRARY_PATH=/usr/lib/wsl/lib` (`:67`), and
  `-v /usr/lib/wsl:/usr/lib/wsl:ro` (`:76`) in its raw `docker run`. `--device` on a missing
  node is a hard fail, so fixing compose alone still leaves ephemeral containers broken.

## A2. Implementation design (resolves open questions §5.1, §5.2)

**Mechanism: compose overlay + auto-detect, riding existing plumbing.** `profile.sh` already has
a `COMPOSE_FILE_ARGS` array with an overlay precedent (`--expose-dev` →
`docker-compose.<profile>.expose-dev.yml`, see `profile.sh:315`, applied at `up`/`recreate`/
`rebuild`/`db-reset`). So:

1. Move the three GPU lines out of `docker-compose.yml` into a new `docker-compose.wsl-gpu.yml`
   overlay (service `ai-sandbox`: `devices`, the `/usr/lib/wsl` volume, `LD_LIBRARY_PATH`).
2. In `profile.sh`, auto-detect and append: `[[ -e /dev/dxg ]]` → add
   `-f docker-compose.wsl-gpu.yml` to `COMPOSE_FILE_ARGS`. `/dev/dxg` is a precise signal —
   that node exists only under WSL2 with GPU paravirtualization; no false positives on bare
   Linux. Provide `SANDBOX_GPU=0|1` as an explicit override in both directions.
3. Same guard in `run-ephemeral.sh` around its three hard-coded lines (build the
   device/env/volume args conditionally into the `docker run` argv).
4. `host_setup/setup-rootless-docker-wsl.sh`: gate the NVIDIA container-toolkit install +
   `nvidia-ctk` config (~15 lines) behind the same detection (the D-Bus block already
   self-guards on `$WSL_DISTRO_NAME`).
5. `verify-sandbox.sh`: report dxg/wsl checks as **"N/A (non-WSL host)"** instead of `warn`
   when off-WSL, and add the §4 recommendation: **hard-fail on uid_map `0 0`** so rootful
   Docker can never silently pass the rest of the suite. (Answers §5.4: hard-fail.)
6. **Decision on §5.2 (second base image): NO for now.** Keep the CUDA base everywhere —
   it runs fine without a GPU, and one shared image preserves the "one image, many profiles"
   model. Costs disk + CVE surface only; revisit if image size becomes a problem.

Effort: a few hours. No security-model change; the WSL machine detects `/dev/dxg` and behaves
exactly as today. Update `justfile` comments + `CLAUDE.md` GPU notes as part of the same change.

## A3. Interaction with the agent-repo-conventions migration (`agent_repo_conventions_advice.md`)

The AGENTS.md/skills restructuring (root advice doc, peer-reviewed 2026-06) is planned but not
started (no `AGENTS.md`, no `.agents/`, CLAUDE.md still monolithic). The two work streams
interact; sequence and adjust as follows:

1. **Land portability FIRST, then the conventions migration.**
   - The conventions' own "Verification Protocol" mandates `profile.sh <p> verify` + `audit`
     after any security-sensitive change — which cannot run on this host until `up` works,
     i.e. until portability lands. Portability is hours; conventions is a multi-file
     restructuring.
   - Conventions migration step 6 (`config/` → `sandbox_templates/`) rewrites paths inside
     `profile.sh` / `init-profile-state.sh` — the same files portability touches. Serializing
     avoids conflicting edits and keeps each diff reviewable under the sensitive-files protocol.
2. **Write the new agent docs substrate-neutral from day one.** The advice's drafts are
   WSL-flavored ("WSL2 host", "host WSL2 rootless Docker daemon" in `dashboard/AGENTS.md`,
   "WSL2 virtual machine boundary" in ARCHITECTURE.md). Since bare Ubuntu is now a first-class
   substrate, AGENTS.md/ARCHITECTURE.md should present **two arms** (WSL2+GPU / bare-Linux
   rootless, auto-detected via `/dev/dxg`) rather than a WSL-shaped happy path. This absorbs
   §4 recommendations #5 (`deployment-substrates.md`) and #6 (substrate-branched NEW-DEVICE
   checklist) into the conventions deliverables instead of standalone docs — write them once,
   in the new structure.
3. **Extend the AGENTS.md "Security-Sensitive Files" list** with the artifacts portability
   introduces/reveals: `docker-compose.wsl-gpu.yml` (an overlay edit can reintroduce devices/
   mounts without touching the base compose) and `scripts/run-ephemeral.sh` (raw `docker run`
   — it must mirror compose hardening by hand).
4. **`container_testing/AGENTS.md` draft needs a no-GPU caveat:** on bare-Ubuntu-no-GPU hosts,
   `torch.cuda.is_available()` → `False` is the *expected* result, not a failure.
5. **CLAUDE.md → AGENTS.md move is a chance to fix staleness:** the current file-structure
   section omits `dashboard/`, and the GPU "Important Notes" ("NOT `--gpus all`", `/dev/dxg`
   passthrough) must be rewritten as WSL-arm-conditional. The repo name `windows-ai-sandbox`
   becomes a partial misnomer — note it in ARCHITECTURE.md; renaming is out of scope.
6. **Housekeeping tie-in:** `REPO-SCAN_in-transit_audit-and-housekeeping.md` quick-win #3
   flags root-level doc sprawl; once AGENTS.md exists, `agent_repo_conventions_advice.md` is
   superseded and should move to `docs/_archive/`.

## A4. Still-open items (carried from §5)

- §5.3 Podman-rootless as first-class target — unchanged, undecided.
- §5.5 headless auth path (`claude login` device-code flow on non-desktop hosts) — unchanged;
  not blocking this host (has a browser).
