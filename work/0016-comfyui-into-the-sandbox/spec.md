# 0016 — Move ComfyUI into the sandbox, retire `my_comfyui/.devcontainer/`

**Status: COMPLETE — signed off 2026-08-28.** All four decisions closed, the
devcontainer is gone, ComfyUI runs in the sandbox on GPU with ComfyUI-Manager
loading cleanly, and the image rebuild + profile recreate are done. Ready to
archive. §11 records what the execution taught that the decisions did not
anticipate — read it before trusting D1's original wording.

**D1's protection is NARROWER than §8 claims — see §11.1.** `network_mode =
offline` gates Manager's catalogue fetches ONLY. It does not gate Manager's
dependency self-install, and it does not gate model downloads. Both were
measured, not inferred.

**Exit rule:** delete this folder, or move to [`docs/_archive/`](../../docs/_archive/),
when the work merges.

**Touches security-sensitive surfaces:** `proxy/allowed_domains.txt` (new egress
for model weights), possibly `Dockerfile` (`libgl1`). Per AGENTS.md, the commit
message must state the security impact and `verify` must pass; run `audit` too —
this is not trivial.

---

## 1. Goal

Run ComfyUI inside the existing `ai-sandbox-<profile>` container instead of its
own dev container, so the repo lives in one place under the same hardening as
every other workspace, and then delete `my_comfyui/.devcontainer/`.

**Owner's framing (2026-08-27):** *"I would like it in the sandbox to keep
everything in the one place"*, and — bounding the egress question — *"I can side
load models from misc places later and drop into the mapped folder manually."*
That second half is load-bearing for D1: the allowlist only has to cover the
**routine** in-app download path, not every host a model might ever come from.

**Repo:** `~/repo/nranthony/my_comfyui` → already visible as
`/workspace/my_comfyui` in `ai-sandbox-nranthony`.

## 1.5 MEASURED — ComfyUI already runs in the sandbox (2026-08-28)

The owner ran it before this spec was signed off, which settles the item's
biggest risk and rewrites several assumptions below. From
`/workspace/my_comfyui/.venv/bin/python comfyui/main.py --listen` inside a profile:

- **The cu130-on-12.6.3-base question is CLOSED — it works.**
  `pytorch version: 2.10.0+cu130`, `Total VRAM 12288 MB`,
  `Device: cuda:0 NVIDIA GeForce RTX 3080 Ti : cudaMallocAsync`,
  `NVIDIA Driver: 610.62`, DynamicVRAM enabled, `comfy-aimdo` initialised against
  the GPU. §5.2 called this "the single most likely thing to sink the item"; it
  did not. Torch's bundled CUDA libs + the `/usr/lib/wsl` driver are sufficient
  on the `-base` image, as expected but now verified rather than assumed.
- **Correcting §2.2:** the venv is *not* stranded. Only the console-script
  shebangs carry `/workspaces/…`; `main.py` is launched by interpreter path, which
  resolves fine. ComfyUI 0.34.1 starts, loads 18 custom node packs, and serves.
  A venv rebuild is still wanted for hygiene (see the dependency warning below)
  but it is no longer a blocker for deleting the devcontainer.
- **The `[comfyui]` block is confirmed necessary, with exact evidence.** Five
  Manager startup fetches fail `403 Forbidden` from `egress-proxy:3128` —
  `custom-node-list.json`, `alter-list.json`, `extension-node-map.json`,
  `model-list.json`, `github-stats.json` — all under
  `raw.githubusercontent.com/ltdrdata/ComfyUI-Manager/main`, plus
  `Cannot connect to comfyregistry` (that is `api.comfy.org`). Manager then logs
  `Due to a network error, switching to local mode` and serves its bundled
  copies. **Read-only browsing works offline; only updates break.**
- **Manager's `network_mode: public` is the cheaper fix.** Setting it to
  `offline` suppresses the five fetches and their tracebacks entirely. If the
  owner only ever side-loads weights, that closes the whole `[comfyui]` question
  without opening any egress. Prefer it.
- **Manager installs Python dependencies at startup** —
  `[ComfyUI-Manager] Using uv as Python module for pip operations` /
  `ComfyUI-Manager: installing dependencies done.` This is a supply-chain surface
  that §7 did not name: running ComfyUI while `[pypi]` is open lets Manager
  install arbitrary packages unattended. It is a second reason to keep `[pypi]`
  closed during ComfyUI sessions, and it is stronger than the node-install point.
- **`--listen` binds `0.0.0.0`.** VS Code's tunnel forwards 8188 regardless, so
  the flag is not needed; dropping it binds loopback only and is strictly
  tighter. Relevant to the `remote.autoForwardPorts: false` guardrail, which
  exists precisely because a `0.0.0.0` bind otherwise surfaces on Windows
  localhost undeclared.
- **Stale devcontainer path, still live:**
  `comfyui/custom_nodes/comfyui-impact-pack/impact-pack.ini` has
  `custom_wildcards = /workspaces/my_comfyui/…` (note `/workspaces/`, the
  devcontainer mount point), producing a startup WARNING and a silent fall back
  to the default path. Add to §5.4 cleanup. Only `comfyui/user/*.log` else
  carries the old path, and those are disposable.
- **Dependency set is inconsistent:**
  `RequestsDependencyWarning: urllib3 (1.26.13) or chardet (7.2.0)/charset_normalizer (2.1.1) doesn't match a supported version!`
  Worth clearing during the §5.2 venv rebuild rather than carrying forward.
- Benign, recorded so nobody chases them: `xFormers not available` (pytorch
  attention is in use), `No OpenGL_accelerate module loaded` (PyOpenGL extra, not
  libGL), triton backend `available: True, disabled: True`, and a cosmetic
  malformed URL from `comfy-mtb` (`http://0.0.0.0,:::8188/mtb`). Alembic migrated
  ComfyUI's SQLite asset DB `0003 → 0006`; it lives under `comfyui/user/`, i.e.
  on the bind mount, so it survives `docker rm` — consistent with the state
  placement rule, no action needed.
- Manager reports `V3.39.2` at runtime while its `pyproject.toml` says `3.39.3`.
  Immaterial to the host census in §2.5, which was read from the checked-out
  `model-list.json` itself.

## 2. Measured facts (2026-08-27)

All verified locally against the checkout; none of it is from memory. Re-check
on pickup — the ComfyUI/Manager versions below will have moved.

### 2.1 The attach flow already works; the devcontainer is not what you use

- `just code <profile> <repo>` → `scripts/code-attach.sh` → a
  `vscode-remote://attached-container+<hex>/<path>` URI naming
  `ai-sandbox-<profile>` on the `rootless` docker context. Its header states the
  relevant half outright: *"needs no devcontainer.json in the repo, so the
  container's hardening is untouched."*
- So editing `my_comfyui` in the sandbox needs **no** work. Today's checkout
  bumps (`v0.18.5 → release/v0.33 → release/v0.34`, per `comfyui/.git` reflog)
  are pure git and already work there.
- **Not a reason to delete it:** Findings A–D in
  [`docs/vscode-integration-security.md`](../../docs/vscode-integration-security.md)
  are **attach-time** injections (`SSH_AUTH_SOCK`, gitconfig copy,
  `credential.helper` shim, orphan UID-0 shell). They fire on *Attach to Running
  Container* too. Removing a devcontainer closes none of them. The one genuine
  anti-devcontainer finding is lifecycle (Reopen makes VS Code drive
  `docker compose up`, bypassing `profile.sh` — Golden Rule 1), and it does not
  apply to `my_comfyui`'s devcontainer, which uses plain `docker build` +
  `runArgs` and never touches compose.

### 2.2 What the devcontainer is still load-bearing for

- `.venv/bin/*` shebangs read `#!/workspaces/my_comfyui/.venv/bin/python3` —
  `workspaceFolder` from `devcontainer.json`. The 247-package env was built
  **inside** that container and does not run from the host or from
  `/workspace/my_comfyui`. Deleting the folder without rebuilding the venv
  strands it.
- `README.md` steps 3, 4 and 8 plus Prerequisites are written around *Reopen in
  Container*; the "What's tracked vs not" table lists `.devcontainer/` as Tier 1.
- `.env.example` exists **solely** to feed `devcontainer.json`'s `--env-file` →
  `set-git-global.sh`. It becomes dead with the folder.
- Base image mismatch: devcontainer is `nvidia/cuda:13.2.0-runtime-ubuntu24.04`,
  the shared sandbox image is `nvidia/cuda:12.6.3-base-ubuntu24.04`
  (`Dockerfile:19`). `requirements.lock` pins torch `+cu130`.
- `.devcontainer/Dockerfile` installs `libgl1` deliberately ("fixes libGL.so.1
  regardless of opencv variant"). **`libgl1` is absent from the shared image** —
  it has `libglib2.0-0t64` only (`Dockerfile:86`).
- `--network=ai-sandbox` in `runArgs` points at a legacy bridge —
  **172.20.0.0/16, zero containers attached**. No overlap with the live profile
  subnets (172.30.108/187/228.0/24). Orphan; dies with the folder.

### 2.3 Port forwarding is NOT a blocker

Correcting an assumption worth writing down: the sandbox publishes no `ports:`
and `sandbox-internal` is `internal: true`, but VS Code forwards ports over its
server tunnel, not via docker publishing.
`docs/vscode-integration-security.md` already prescribes
`forwardPorts: [8080, 8501, 8188]` in the attached-container configuration file —
**8188 is ComfyUI's port**. The UI reaches the browser without any compose change.

### 2.4 Current allowlist state (`proxy/allowed_domains.txt`)

73 active domain lines. Relevant to this work:

| Section | State | Consequence |
|---|---|---|
| `[pypi]` — `.pypi.org`, `.files.pythonhosted.org`, `.astral.sh` | **open** (320–322) | venv rebuild works as-is |
| `[pytorch]` — `download.pytorch.org` | **open** (325) | `+cu130` wheels resolvable as-is |
| `[git]` — `github.com`, `api.github.com`, `codeload.github.com` | **open** (309–311) | Manager can clone custom nodes |
| `raw.githubusercontent.com` | **commented** (314) | **blocks Manager's own DB** — see 2.5 |
| `[apt]` — `archive.ubuntu.com`, `security.ubuntu.com` | commented (440–441) | `libgl1` needs `--with apt` or a Dockerfile line |
| huggingface / civitai / comfy.org | **absent entirely** | every model download blocked |

Note the in-repo comment conventions when editing: an always-on section is
`# --- Name [tag] ---` with bare domain lines; a planning-mode section needs the
double-comment header `# # --- Name [TAG] ---` and `# domain` lines for
`with-egress.sh` to find and strip them.

### 2.5 Where models actually come from — census, not guesswork

Counted from `ComfyUI-Manager` 3.39.3's curated `model-list.json` (527 entries
with a URL), which is what the in-app Model Manager offers:

| Host | Entries | What |
|---|---|---|
| `huggingface.co` | 479 (91%) | the overwhelming majority |
| `github.com` | 25 | release assets |
| `dl.fbaipublicfiles.com` | 11 | Meta — SAM, detectron |
| `civitai.com` | 6 | |
| `heibox.uni-heidelberg.de` | 1 | original LDM/VAE weights |
| `openaipublic.azureedge.net` | 1 | CLIP |
| `storage.googleapis.com` | 1 | already open for `[kaggle]` |

`node_db/new/model-list.json` adds 50 × `huggingface.co` + 8 ×
`dl.fbaipublicfiles.com`; `node_db/legacy` adds 11 × `huggingface.co` + 2 ×
`github.com`. **No new hosts** beyond the table.

Manager's control plane, separately from weights:
- `glob/manager_core.py:51` — `DEFAULT_CHANNEL =
  "https://raw.githubusercontent.com/ltdrdata/ComfyUI-Manager/main"` (node +
  model DB). Currently **denied**.
- `glob/cnr_utils.py:14` — `base_url = "https://api.comfy.org"` (Comfy Registry).
- `glob/manager_core.py:3042` — `registry.comfy.org` (node reference links).
- `app/frontend_management.py:128` — `api.github.com/repos/{owner}/{repo}/releases`
  for frontend updates; asset bytes come from GitHub's release-asset hosts.

**ComfyUI core does not auto-download models** — no `hf_hub_download` /
`snapshot_download` / `resolve/main` anywhere outside `custom_nodes/`. But seven
installed custom nodes *do* fetch at node-execution time (`from_pretrained` /
`hf_hub_download`): `comfy-mtb`, `comfyui-art-venture`,
`comfyui-depthanythingv2`, `comfyui-easy-use`, `comfyui-kjnodes`,
`comfyui_controlnet_aux`, and Manager itself. These are the silent HF hits that
will surface as `TCP_DENIED` mid-workflow rather than in a visible download UI.

### 2.6 The CDN problem — the byte-serving host is runtime-supplied

This is the part an allowlist cannot get from source, and the reason §5 makes
Squid's access log the source of truth rather than this document:

- `huggingface_hub` **1.7.2** with `hf_xet` **1.4.2** installed, so Xet is
  active. `constants.py:274` — the CAS endpoint arrives in an
  `X-Xet-Cas-Url` **response header**. The download host is chosen by the server
  at request time and appears nowhere in the source.
- The classic (non-Xet) path is no better: `huggingface.co/…/resolve/…` 302s to a
  CDN host that is also server-chosen.
- `manager_downloader.py` uses `requests` (follows redirects silently) and
  `huggingface_hub.HfApi`, so the redirect is invisible to the caller — a denial
  presents as a failed download, not as a named blocked host.
- **Off-switch exists and is verified in the installed source:**
  `HF_HUB_DISABLE_XET` at `constants.py:283`, consumed by `is_xet_available()`
  at `utils/_runtime.py:159`. Setting it forces the classic CDN path, which is a
  narrower and more stable set of hostnames. This is D3.

### 2.7 Model storage

`comfyui/models/` is **71 GB**, inside `comfyui/` (gitignored) under
`~/repo/nranthony/`, i.e. inside the profile's `/workspace` bind mount. It
already satisfies AGENTS.md's state-placement rule (host dir, survives
`docker rm`), so nothing is *broken* — but it sits in a repo tree, which is the
shape the pipeline repo moved away from (see the relocation of workspace Parquet
data to `$PIPELINE_WORKSPACES_DIR`). `comfyui/extra_model_paths.yaml.example`
exists and is the supported relocation mechanism. This is D2, and it is also
where the owner's "drop into the mapped folder manually" lands.

## 3. DECISIONS — present to the owner before implementing

**D1 — how wide does model-weight egress go?** *(security boundary; settle first)*

**The blocks are written and committed CLOSED** — see `proxy/allowed_domains.txt`,
three gated planning-mode sections added 2026-08-27 immediately before the
DROPPED banner. They add **zero** live domains (live count unchanged at 73), so
nothing is decided by their existence; D1 is now purely *which tags you open*:

| Tag | Opens | Covers |
|---|---|---|
| `[comfyui]` | `raw.githubusercontent.com`, `api.comfy.org`, `registry.comfy.org` | Manager's DB + Registry — **not optional**, the UI cannot populate without it |
| `[comfyui-models]` | `huggingface.co` (+ CDN hosts from §5.1) | 91% of the curated list, all seven auto-downloading custom nodes |
| `[comfyui-models-extra]` | `dl.fbaipublicfiles.com`, `civitai.com`, `heibox.uni-heidelberg.de`, `openaipublic.azureedge.net` | the remaining ~9% |

Verified by replaying `open_section()` against a copy: each tag opens exactly the
domains listed and every prose line stays commented.

So the options are:

- **(a) narrow** — `with-egress.sh <p> --with comfyui,comfyui-models -- '<cmd>'`.
  Everything off the curated HF path is a manual side-load, which is what the
  owner said they would do anyway.
- **(b) wide** — add `,comfyui-models-extra`. One word's difference, by design.
- **(c) always-on instead of gated** — move the blocks out of planning mode.
  **Not recommended**, and it additionally requires adding the tags to
  `ACCEPTED_OPEN_TAGS` in `scripts/audit/probes/proxy.py` with a written
  rationale above the block, or every audit run reports WEAK forever.

Recommendation: **(a), gated**. Model downloads are a deliberate human action;
a workflow run should not be able to reach HF unattended. Escalate to (b) if the
long tail actually bites.

All three tags were added to `GATED_TAGS` in `scripts/audit/probes/proxy.py` in
the same change — without that the audit's `gated_blocks_default_off` check
cannot see them, and a block left open by a `with-egress.sh` run that died before
its trap fired would go unreported.

**D2 — where do the 71 GB of models live?** Leave in
`~/repo/nranthony/my_comfyui/comfyui/models/`, or relocate outside the repo tree
(e.g. `~/.ai-sandbox/data/comfyui-models/` or a dedicated host dir) and point at
it with `extra_model_paths.yaml`? Relocating means a new bind mount, which is a
`docker-compose.yml` edit — and per Golden Rule 2 it must stay
substrate-neutral, so it cannot be conditional on GPU. It is also the "mapped
folder" the owner wants to drop files into by hand, so its path should be a
deliberate choice rather than an artifact of where the clone happens to be.

**D3 — Xet on or off?** `HF_HUB_DISABLE_XET=1` trades download speed for a
narrower, more predictable CDN host set. Decide before §5.1, because it changes
which hosts the observation run produces.

**D4 — `libgl1`: shared image or per-run apt?** Adding it to the `Dockerfile`
costs every profile a small layer and a full rebuild (and per AGENTS.md the
install-layer ORDER is load-bearing — `dockerfile-order.test.sh` must pass).
The alternative is `with-egress.sh --with apt` at setup time, which leaves the
shared image untouched but has to be redone on every container recreate. Note
ComfyUI is not the only opencv consumer likely to want this.

**Updated 2026-08-28 — this is masked, not solved.** The 1.5 run threw no
`libGL.so.1` error, but the venv has **all three** opencv variants installed:
`opencv_python`, `opencv_contrib_python` and `opencv_python_headless`, all
4.13.0.92. The headless wheel was installed last (20:25:57 vs 20:24:32) so it
currently wins the `cv2` import, which is the only reason there is no failure.
Any reinstall that reorders them reintroduces it. That is exactly what the
devcontainer's Dockerfile comment meant by "fixes libGL.so.1 **regardless of
opencv variant**" — its author hit this. So D4 stands, and the §5.2 venv rebuild
should also resolve the variant collision (pick headless, drop the other two)
rather than relying on install order.

## 4. Non-goals

- Hardening `my_comfyui/.devcontainer/` (`--userns=host`, no seccomp, no
  `cap_drop`, open internet on the legacy bridge). That was the alternative to
  this item, not part of it. It dies with the folder.
- Publishing 8188 on the host via compose `ports:`. VS Code's tunnel covers it
  (§2.3) and a published port on `sandbox-internal` would be a real posture
  change.
- Anything Hunyuan3D. The README marks it incomplete; it stays incomplete.
- Rewriting `my_comfyui`'s git history or the legacy `environment.yml` /
  `hunyuan3d_2_1_env.yml` conda specs.
- Bumping the shared base image — that is [0014](../0014-bump-base-image-to-cuda-12.9.1/spec.md),
  and §6 below is the only place the two touch.

## 5. Steps (after §3 sign-off)

### 5.1 Observe before allowlisting — this is the whole method

Because §2.6 means the CDN hosts are not derivable from source, do **not** write
speculative CDN entries. Instead:

1. Open the decided base hosts (`huggingface.co`, `raw.githubusercontent.com`, …).
2. Pull one small model through the in-app Model Manager.
3. Read `TCP_DENIED` lines out of Squid's access log for the profile and add the
   **exact** hosts observed — the same procedure the `[numerai]` block documents
   for its dynamically-named S3 buckets, and the same "add the specific host, no
   parent wildcards" rule the `[git]` block states.
4. Repeat with Xet in whichever state D3 chose.

**Capture the log live.** Per the standing note, proxy crashes and evidence in
`cache.log` are forensically silent (tmpfs, `docker logs` blind) — if the
observation run is not captured while it happens, it is gone.

### 5.2 Container-side

- Add `libgl1` per D4.
- Rebuild the venv at the sandbox path: `uv venv` + `uv pip install -r
  requirements.lock --extra-index-url https://download.pytorch.org/whl/cu130`
  from `/workspace/my_comfyui`. `[pypi]` and `[pytorch]` are already open, so no
  widening needed — but `with-egress.sh` still applies the `UV_EXCLUDE_NEWER`
  age gate, and a 247-package lock against a 7-day window may need
  `--allow-fresh "<reason>"`. Budget for that; the reason is mandatory and
  recorded.
- ~~Verify `+cu130` wheels run on the `12.6.3-base` image.~~ **DONE — §1.5.**
  torch 2.10.0+cu130 on the RTX 3080 Ti with driver 610.62, GPU allocated,
  DynamicVRAM enabled. No further GPU verification needed for this item.
- Resolve the opencv variant collision while rebuilding (see D4).

### 5.3 VS Code

Add `8188` to `forwardPorts` in the attached-container configuration file for
the `windows-ai-sandbox` image (it is already the prescribed value in
`docs/vscode-integration-security.md`, so this may be a no-op).

### 5.4 Only once ComfyUI actually starts and renders in the browser

- Delete `my_comfyui/.devcontainer/` and `.env.example`.
- Rewrite `my_comfyui/README.md`: Prerequisites, steps 3/4/8, and the
  "What's tracked vs not" table all name the devcontainer. Replace with the
  `just code <profile> my_comfyui` flow and the new model path from D2.
- Note the ComfyUI pin drift while in there: the README pins `v0.18.5` /
  `7782171a`, the checkout is at `v0.34.1` / `7597a5a0`.
- Fix `custom_wildcards` in
  `comfyui/custom_nodes/comfyui-impact-pack/impact-pack.ini` — still
  `/workspaces/my_comfyui/…` (§1.5).
- Re-export the ComfyUI-Manager snapshot into `snapshots/` if node versions moved.
- `docker network rm ai-sandbox` (the 172.20.0.0/16 orphan) — separate from the
  repo change, owner's call.

**Order matters: do not delete before §5.2 passes.** The venv is only rebuildable
with network access and a working `[pypi]` path; deleting the devcontainer first
means the fallback is gone if the cu130-on-12.6.3 question in §5.2 goes badly.

### 5.5 Repo-side obligations

- `verify` (tier 1) and `audit` (tier 2) — the allowlist is a security-sensitive
  surface.
- `bash scripts/with-egress.test.sh` (82/82) if a new gated section is added —
  it locks the allowlist parsing across five parsers, including
  `list_denied_domains` in `profile.sh`.
- `bash scripts/dockerfile-order.test.sh` (8/8) if D4 adds a `Dockerfile` line.
- `bash scripts/private-names-check.sh` — `proxy/allowed_domains.txt` and
  `docker-compose.yml` are scanned public surfaces.
- Commit message states the egress impact explicitly.
- ARCHITECTURE.md if D2 adds a bind mount.

## 6. Interaction with 0014

If [0014](../0014-bump-base-image-to-cuda-12.9.1/spec.md) lands first, the base
moves to CUDA **12.9.1** — still 12.x, so the §5.2 cu130-wheel question is
unchanged in kind, but re-test rather than assuming the earlier result carries.
If this item lands first, 0014's GPU re-verify should include a ComfyUI smoke
run, since the sandbox will then have a real CUDA workload in it.

## 7. Security note

This item **widens egress** — that is its main risk. Three things bound it:

1. The container that gains reach to `huggingface.co` is the same container the
   agent runs in. HF hosts arbitrary user-uploaded repos, so this is a general
   fetch capability, not a narrow vendor API. D1(c)'s gated tag is what keeps it
   closed during agent runs; that is the reason to prefer it.
2. Model weights are **executable-adjacent** — `.ckpt` is pickle. ComfyUI
   defaults to `safetensors` and Manager 3.39.3 ships a `security_check.py`, but
   nothing in this repo's guardrails inspects downloaded weights.
3. ComfyUI-Manager installs custom nodes as **arbitrary Python from GitHub**,
   executed in-process. That is true today in the devcontainer and stays true
   after the move — but after the move it happens inside the sandbox next to
   agent credentials, rather than in an isolated container. This is the one
   genuine posture *regression* in the item and should be stated in the commit
   message rather than glossed. Mitigation to consider under D1: keep node
   installation on the gated tag too, so it is a deliberate act.

## 8. Execution log (2026-08-28)

**D1 = offline.** Zero egress opened. The three gated blocks stay closed and
committed, available if the decision is ever revisited.

Done, in `~/repo/nranthony/my_comfyui` (uncommitted there — the owner commits):

- **`network_mode = public` → `offline`** in
  `comfyui/user/__manager/config.ini`. Verified against Manager's source, not
  guessed: valid values are `public | private | offline` (`manager_core.py:1774`,
  lowercased at `:1745`), and `manager_server.py:1844` gates all five startup
  fetches *and* the comfyregistry reload behind `!= 'offline'`, with
  `manager_core.py:2297` falling back to the bundled file. Read at startup only.
- **New `justfile`** carrying the toggle (`net-offline` / `net-public` /
  `net-status`) plus `run` / `run-listen`. The toggle needed a home: the config
  file lives under the gitignored `comfyui/` tree, so a hand `sed` is not
  reproducible and does not survive a re-clone.
- **`run` drops `--listen`** — binds loopback only. VS Code's tunnel forwards
  8188 from an attached container regardless, so the `0.0.0.0` bind bought
  nothing and is exactly what `remote.autoForwardPorts: false` exists to catch.
  `run-listen` keeps the old behaviour for when something outside must reach it.
- **`impact-pack.ini`** `custom_wildcards` repointed from `/workspaces/…` to
  `/workspace/…`. The target directory exists, so this clears the startup
  WARNING and the silent fallback.
- **`.devcontainer/` and `.env.example` deleted.**
  `ROOTLESS-DOCKER-NOTES.md` and `GPU-FIX-MIGRATION.md` were NOT deleted with
  them — they are host-setup narrative, not container plumbing, so they moved to
  `docs/_archive/` under this repo's own "archived, not deleted" ethic. Both are
  superseded here (the `/dev/dxg` vs `--gpus all` decision is the header comment
  of `docker-compose.wsl-gpu.yml`; the container-root rationale is in
  ARCHITECTURE.md) but they are that repo's history.
- **`README.md` rewritten** — attach flow, the `with-egress.sh --with
  pypi,pytorch` install recipe, the offline-Manager step, ComfyUI pin corrected
  `v0.18.5`/`7782171a` → `v0.34.1`/`7597a5a0`, `.env` references removed, and the
  tracked-vs-not table updated. The cu130-on-12.6-base result is stated there so
  the next person does not re-derive it.
- **`.gitignore`** — `.env` stays ignored, with a note saying nothing consumes
  it any more.

### Not done, deliberately

- **The opencv variant collision (D4).** All three of `opencv-python`,
  `opencv-contrib-python` and `opencv-python-headless` are installed; headless
  currently wins the `cv2` import by install order alone. **Uninstalling the
  other two is not safe right now:** `opencv-python-headless` lacks the contrib
  modules (`cv2.ximgproc` and friends) that `comfyui_controlnet_aux`
  preprocessors use, and the correct single package —
  `opencv-contrib-python-headless` — is not installed and cannot be fetched with
  `[pypi]` closed. Doing the uninstall now would break nodes with no way back.
  Fold it into the next `with-egress.sh --with pypi` window, or settle D4 in
  favour of `libgl1` in the shared image, which makes the variant irrelevant.
- **The venv rebuild.** It works as-is; the `urllib3`/`chardet` mismatch warning
  is cosmetic. Batch it with the opencv fix rather than opening egress twice.
- **D2 and D3** — CLOSED 2026-08-28, see §10. D4 landed, see §9.
- **`docker network rm ai-sandbox`** — the 172.20.0.0/16 orphan with zero
  containers attached. Owner's call, unrelated to the repo change.

### Worth knowing

`security_level = normal` in the same Manager config. Per
`manager_server.py:109-121` that **permits** `middle`-gated actions — which is
custom-node install/uninstall/update — and blocks only `high`. Setting it to
`strong` would close Manager's install path entirely and directly addresses the
§7 residual (arbitrary Python from GitHub executed in-process, now beside agent
credentials). Left at `normal` because it would stop the owner installing nodes
and was not part of D1, but it is the natural companion decision.

## 9. D4 landed — `libgl1` in the shared image (2026-08-28)

Added as its own `RUN` layer in the `Dockerfile`, immediately after the
Chromium/Playwright library block and well above the ordering chain that
`dockerfile-order.test.sh` guards (the chain starts at the beads install; the
new layer sits ~300 lines earlier, so nothing in it can reorder).

**Why baked rather than left to the workspace** — two independent reasons, both
worth keeping because either alone invites "just pin headless in the project":

1. `apt-get` cannot run at container runtime here. `cap_drop: ALL` +
   `no_new_privs` stop it acquiring locks, so the alternative is a
   `with-egress.sh --with apt` window on **every container recreate**, not once.
2. A workspace does not reliably get to choose its opencv variant. pip installs
   whichever one a transitive dependency asks for, and several ComfyUI custom
   nodes pull the non-headless build. Pinning `opencv-python-headless` in one
   project does not stop a sibling dragging in the other. Providing `libGL.so.1`
   makes every variant work and deletes the failure mode rather than dodging it.

`libglib2.0-0t64` — opencv's other common runtime need — is already installed by
the Chromium block, so this is genuinely one package, ~1 MB.

`dockerfile-order.test.sh` 8/8, `just test-offline` all ten suites green.

**Owner action required:** this does nothing until the image is rebuilt and each
profile recreated.

```
scripts/profile.sh build
scripts/profile.sh <profile> up      # per profile, to recreate onto the new image
```

**Consequence for the deferred opencv cleanup (§8).** With `libgl1` present the
variant collision stops being a correctness problem — any of the three works. It
is still untidy, and `opencv-contrib-python-headless` alone remains the intended
end state, but it is no longer urgent and no longer needs its own egress window:
fold it into the next venv rebuild whenever that happens for other reasons.

## 10. D2 and D3 closed — no action (2026-08-28)

**D2 — models stay where they are.** `comfyui/models/` remains at
`~/repo/nranthony/my_comfyui/comfyui/models/` (71 GB: 39 G checkpoints, 15 G
controlnet, 5.1 G ipadapter, 5.0 G depthanything, 4.6 G diffusers). No compose
change, no new bind mount.

Owner's reasoning, recorded because it is what makes this the right call rather
than a deferral: much of the tree is **testing weights that do not need to
survive**, and anything actually in use is re-downloadable. The tidiness
argument for relocating (a 71 GB blob inside a git working tree) does not earn a
`docker-compose.yml` edit against that. It is also time-boxed — the plan is to
move heavier GPU work to hosted ComfyUI services once the workflows and
pipelines are settled here, which would make a carefully-mounted local model
directory short-lived infrastructure.

The existing placement already satisfies the state-placement rule (host bind
mount, survives `docker rm`) and disk is not a constraint (627 GB free on WSL
ext4), so nothing is at risk. If it is ever revisited, the mechanism is
`comfyui/extra_model_paths.yaml` plus one substrate-neutral bind mount.

**D3 — Xet: moot, no setting changed.** `HF_HUB_DISABLE_XET` only matters when
weights are pulled *through the proxy*, because its point was narrowing which
CDN hosts have to be allowlisted. D1 chose `network_mode = offline` and opened
no egress, so nothing routes through Squid and there is no host set to narrow.
Left at the default (Xet active, `hf_xet` 1.4.2 installed) — it is the faster
path and costs nothing here.

**Revisit both only if `[comfyui-models]` is ever opened.** At that point D3
comes back first (decide Xet *before* the §5.1 observation run, since it changes
which hosts appear), and D2 becomes worth re-asking only if the local tree is
still growing.

## 11. What execution taught — corrections to the decisions (2026-08-28)

Everything below was measured during the actual migration, after §3's decisions
were closed. Where it contradicts an earlier section, this section is right.

### 11.1 D1 CORRECTION — `network_mode = offline` is narrower than §8 claims

§8 records D1 as "offline, zero egress opened", with the implication that
offline closes Manager's network behaviour. It does not. Manager has exactly
**two** `network_mode` checks, and neither is on the paths that matter most:

| Location | What it actually gates |
|---|---|
| `manager_server.py:2075` | the five startup catalogue fetches |
| `manager_core.py:2435` | `get_data_by_mode` falling back to cache |

Two things it does **NOT** gate, both measured live:

1. **Manager's dependency self-install.** At startup Manager runs its own
   `uv pip install` for `requirements.txt` (GitPython, PyGithub, matrix-nio,
   transformers, huggingface-hub, typer, rich, typing-extensions, toml, uv,
   chardet). This reaches PyPI directly and offline does not stop it. See §11.3.
2. **Model downloads.** `install_model` (`manager_server.py:1721`) checks
   `is_allowed_security_level('middle')` and a URL whitelist — there is no
   `network_mode` check on the route. Models download normally with offline set.

So offline suppresses catalogue *refreshes* and the startup tracebacks. It is
not a network kill switch, and it must not be described as one. The real control
on model fetches is `security_level` plus the model-list whitelist, which is the
§3 Manager decision doing its job.

### 11.2 `[pytorch]` needed THREE hosts, found one at a time

D1 opened no egress, and the always-on set is still 69 domains — that half of §8
stands. But installing torch cu130 grew the **gated** `[pytorch]` tag from one
host to three:

```
download.pytorch.org      the simple index + .metadata probes
download-r2.pytorch.org   the wheel BYTES (Cloudflare R2) — index 302s here
pypi.nvidia.com           NVIDIA's index, which the cu130 index links out to
```

Each surfaced only once the previous one was allowed, and each failed as
`tunnel error: unsuccessful` — a message that reads as a network fault, not an
allowlist gap. Evidence at the time: 52x `TCP_TUNNEL/200 download.pytorch.org`,
12x `TCP_DENIED/403 download-r2.pytorch.org`, then 13x `TCP_DENIED/403
pypi.nvidia.com`. This is §2.6's CDN rule holding twice over: **observe the host
in Squid's log, never predict it.** Expect the same for `huggingface.co`, which
now serves bytes through Xet (`hf-xet` is installed in the venv).

### 11.3 A ComfyUI startup installed 63 packages OUTSIDE `with-egress.sh`

With `[pypi]` left open after an install window, starting ComfyUI let Manager
self-install 63 packages: no OSV pre-flight, no age gate, no `depgate.jsonl`
record. **8 of the 64 were younger than the 7-day quarantine**, including
`gitpython 3.1.61` published ~11 hours earlier, `uv 0.12.7`, and
`cryptography 50.0.1`. OSV was clean on all of them, which for a package that
age means very little.

Mitigating: they landed in `/root/.venv` (the wrong venv — §11.4), which nothing
loads, and which the recreate discarded. So it was a **control bypass, not a
compromise**. But it is a concrete demonstration that ADR-0003's "with-egress is
the only route by which a dependency can enter a profile" holds only while the
tags are closed — an application that self-installs will use any open tag.

The lesson for operating ComfyUI: close `[pypi]` before starting it, or accept
that Manager's dependency resolution is ungated.

### 11.4 Manager installed into the WRONG venv, and why

`ModuleNotFoundError: No module named 'git'` — Manager installed GitPython into
`/root/.venv` (Python 3.12.3, the image's build venv) while ComfyUI ran under
`/workspace/my_comfyui/.venv` (3.13.15), so Manager failed to import entirely.

`manager_util.py:49-79` picks its package manager in three steps:

| | Attempt | Result |
|---|---|---|
| 1 | `sys.executable -m pip` | failed — uv-created venvs ship no pip |
| 2 | `sys.executable -m uv` | failed — uv not in the venv |
| 3 | `shutil.which('uv')` → `['uv','pip']` | taken — **no `--python`**, target is ambient |

Only 1 and 2 bind to the running interpreter. **Fix: install `pip` AND `uv` into
the workspace venv**, which makes step 2 win and pins every later install to the
right interpreter. Because `.venv` is on the host bind mount, this survives
`docker rm` and Manager never self-installs again — verified: a clean start now
logs `Using Python 3.13.15 environment at: /workspace/my_comfyui/.venv` and
installs nothing.

### 11.5 The cu130 install needs `--allow-fresh`; requirements.txt needed it too

Neither was anticipated. torch pins CUDA wheels (`cuda-toolkit`,
`cuda-bindings`, `nvidia-cudnn-cu13`) published inside the 7-day window, so the
age gate makes resolution unsatisfiable until suppressed. Separately,
`comfyui-workflow-templates 0.11.48` and its four exact-pinned siblings plus
`comfy-aimdo 0.4.15` are one upstream release published 2026-08-25 — five
packages, one decision.

Recording the shape because it recurs on every ComfyUI upgrade: **ComfyUI's
release train moves faster than a 7-day quarantine**, so a `--allow-fresh` window
with a real reason is the normal path here, not an exception.

### 11.6 Image changes this work added beyond D4

D4 was `libgl1`. Execution added, in the same shared image:

- **Python 3.12.14 + 3.13.15 baked** (`uv python install`, ~207 MB) — ComfyUI
  moved to 3.13 and the interpreter download needs GitHub release-asset hosts
  that live only in closed gated blocks. The build bypasses Squid; a running
  container does not.
- **`UV_PYTHON_INSTALL_DIR=/opt/uv/python`** — uv's default is the 256 MB noexec
  ephemeral `/root/.local` tmpfs, where an interpreter installs and then cannot
  execute, and vanishes on recreate taking `.venv/bin/python`'s symlink with it.
  `/root/.cache` looks right and is wrong: it IS a bind mount, so anything baked
  there is shadowed at container start.
- **`UV_PYTHON_BIN_DIR=/usr/local/bin`** — same trap one level down; uv's
  convenience symlinks default into the noexec tmpfs.
- **`UV_LINK_MODE=copy`** — the cache and every workspace venv are separate bind
  mounts, and Linux returns `EXDEV` across mount points even on one device, so uv
  can never hardlink here and warned on every install.

### 11.7 Dependency risk scan — point-in-time, 2026-08-28

Against the full 70-package resolved set of `comfyui/requirements.txt`: **zero
OSV advisories**; **every pinned version has a wheel**, so Gate 3's
`no-build = true` needs no exception and no `setup.py` runs at install;
`comfy-aimdo` and `comfy-angle` carry PEP 740 attestations binding them to
`Comfy-Org/*` via Trusted Publishing. The `comfyui-workflow-templates` family is
vouched for structurally — the parent declares its four siblings as exact pins
and all were published within 29 seconds.

**This scan had to be run by hand.** `scripts/profile.sh <p> deps` does not cover
`my_comfyui` at all: it scans the workspace root plus each immediate child that
has a manifest AT ITS ROOT, and ComfyUI's is at `comfyui/requirements.txt`. The
summary printed 11 repos and said nothing about the omission. Filed as
**work/0018**.

### 11.8 Final verified state

```
libGL.so.1 present · python3.13 → 3.13.15 · python3.12 → 3.12.14
UV_LINK_MODE=copy · UV_PYTHON_INSTALL_DIR=/opt/uv/python · UV_PYTHON_BIN_DIR=/usr/local/bin
torch 2.13.0+cu130 · cuda True · RTX 3080 Ti · 12288 MB VRAM
ComfyUI 0.34.1 · Manager V3.41 loaded, network_mode: offline, installs nothing
allowlist: 69 live domains (baseline); every ComfyUI tag closed
verify: 52 passed | 0 failed | 1 pre-existing ADR-0004 warning
```

`therapod` and `fluidmomenta` remain on the previous image. Out of scope for
this item — they need a routine `up` whenever convenient.
