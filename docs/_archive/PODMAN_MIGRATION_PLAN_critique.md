# Podman Migration Plan — Critique

Review of `PODMAN_MIGRATION_PLAN_gemini.md` against the realities of this repo
(WSL2 Ubuntu 24.04, rootless Docker, NVIDIA GPU passthrough via `/dev/dxg`,
Squid sidecar egress, profile-based state under `/root/`).

**TL;DR:** The plan is a serviceable high-level skeleton (~40% finished design,
~60% optimistic skeleton). It papers over the parts that are actually hard on
WSL2 + this repo. Combined with a ~0.5/10 marginal-security estimate vs. the
current rootless-Docker + container-UID-0 + userns model, **the migration is
not worth doing now**. Recommended path: add the `DS-0002` ignore today, leave
a tracking note to revisit when either (a) idmapped-mount support lands in
Docker compose, or (b) macolima migrates to Podman first so we can copy the
working pattern.

---

## 1. Security delta — what we'd actually gain

The big hardening jump is **rootless Docker + userns + cap_drop:ALL + seccomp +
no-new-privileges**. Most of that is already in place. Container-escape blast
radius is identical between today's setup and Podman+keep-id:

| Setup | Container escape lands as |
|---|---|
| Rootful Docker | host UID 0 (real root) — catastrophic |
| **Rootless Docker, container UID 0 → host UID 1000 (today)** | host UID 1000 (your user) |
| **Podman + `--userns keep-id`, container UID 1000 → host UID 1000** | host UID 1000 (your user) |

The only real delta is **intra-container privilege after a foothold**: today a
foothold (malicious dep, library RCE, prompt-injection-driven shell) lands as
container root; under Podman+keep-id it'd land as UID 1000. With cap_drop:ALL
+ seccomp + no-new-privs already in force, container-root's extra capabilities
are limited to:

- Tampering with `/usr/local/bin/claude`, `/etc/`, system Pythons (ephemeral —
  rebuilt from image, doesn't survive `down`/`up`).
- Read/write anywhere in the container's rootfs.
- chown files.

What it **can't** do (already neutralized):

- Add capabilities (no-new-privs, cap_drop:ALL).
- Mount filesystems, raw sockets, ptrace outside its namespace, load kernel
  modules (caps dropped, seccomp).
- Reach the network outside the Squid allowlist (`internal: true`).
- Touch host files outside `~/repo/<profile>/` (no other bind mounts).

A narrower, real win: a few historical kernel-escape CVEs needed container UID
0 specifically (vs cap-bound UID 0). Running as UID 1000 closes that subclass.
These are rare and seccomp typically blocks them anyway.

**Magnitude:** if rootful → rootless+userns is ~8/10, today → Podman+keep-id+
non-root is ~0.5/10. The escape ceiling doesn't change, only the intra-container
floor.

---

## 2. Where the plan is right

- `userns_mode: keep-id` is the correct mechanism — that's the killer Podman
  feature versus rootless Docker.
- Network model translates cleanly (`internal: true` works in Podman networks).
- Phase ordering (host prep → image → compose → IDE → verify) is sane.
- Calls out CDI as the GPU path, which is correct in spirit (just not on WSL2;
  see §3.2).

---

## 3. Where the plan is wrong or incomplete

### 3.1 Podman 5.x on Ubuntu 24.04 (§2.1)

> `sudo apt install -y podman podman-compose`

Ubuntu 24.04 main repos ship **Podman 4.9.3**, not 5.x. The plan says
"Podman 5.0+ is required for `pasta`" — `apt install` won't give you that. The
Kubic OBS repos that used to backport Podman to Ubuntu **stopped publishing
for Ubuntu in 2024**. You'd need to either build from source, use cri-o/kubic
archives, or accept 4.9 + slirp4netns. The plan's prerequisite is unmet.

### 3.2 NVIDIA CDI on WSL2 (§2.3, §4.1) — **the biggest hole**

`nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml` assumes real
`/dev/nvidia*` device nodes. **WSL2 doesn't have those.** Your current setup
works because the GPU is exposed via `/dev/dxg` + a bind-mount of
`/usr/lib/wsl/lib` (the Windows-side driver shim) — which is exactly why
CLAUDE.md says *"NOT `--gpus all` (broken under NVIDIA Container Toolkit
≥1.18)"* and pins toolkit `1.17.8-1`.

`devices: - "nvidia.com/gpu=all"` (CDI syntax) will fail or produce a spec that
points at non-existent devices. The plan acknowledges this in §7 as a
*"fallback"* — but on WSL2 the manual `/dev/dxg` + `LD_LIBRARY_PATH` path is the
**primary** route, not a fallback. The whole CDI section is essentially
aspirational here.

### 3.3 The image refactor is bigger than §3.1 admits

The plan shows ~6 lines of Dockerfile changes. Reality is wider:

- All persistent-state binds in `docker-compose.yml` and
  `init-profile-state.sh` target `/root/.claude`, `/root/.claude.json`,
  `/root/.cache`, `/root/.config` — every one needs to become `/home/agent/...`.
- The `tmpfs` block already has `/root/.npm-global` and `/root/.local` with
  `uid=1000,gid=1000` (a clue that even the current setup is half-aware of
  this) — paths need updating.
- The `claude` npm install puts files in `/usr/lib/node_modules/` owned by
  root; agent only needs read+execute, which works, but agent can't
  `npm update -g` self-updates without elevation. Behavior change.
- The `chown agent:agent /usr/local/bin/uv*` line is **actively wrong** —
  making the agent the owner of its own toolchain lets a compromised agent
  overwrite `uv`. World-execute is sufficient; ownership should stay root.
- `claude-settings.json` template, `.zshrc`/`.p10k.zsh` paths in `config/` all
  currently install to `/root/...` via the Dockerfile. Multi-file move.

### 3.4 The `egress-proxy` sidecar disappears (§4)

The compose snippet shows only `ai-sandbox`. The existing setup has a Squid
sidecar with hot-reload semantics, two networks, and the `internal: true`
boundary that's *the entire egress story*. The plan needs to preserve that
whole service block — and verify Podman networks behave the same with two
services (they do, but `pasta` networking has known quirks with multi-service
rootless setups that `slirp4netns` handles differently).

### 3.5 VS Code config (§5) is incorrect

```json
"customizations": { "vscode": { "settings": { "dev.containers.dockerPath": "podman" } } }
```

`dev.containers.dockerPath` is a **user/workspace** setting consumed by VS
Code *before* it parses `devcontainer.json` — putting it inside
`customizations.vscode.settings` (which applies to the *remote* VS Code Server
inside the container) does nothing for runtime selection. The right place is
host VS Code's `settings.json`, or `DOCKER_HOST=unix:///run/user/1000/podman/podman.sock`
in your shell. The plan as written would silently keep using Docker.

### 3.6 Verification regresses

§6 invents a 4-line verifier instead of reusing `scripts/verify-sandbox.sh`,
which already checks CapEff=0, NoNewPrivs=1, Seccomp=2, bwrap/socat/ssh absent,
credential-helper scrub, SSH_AUTH_SOCK leak, etc. None of those should be
dropped — they all still apply under Podman, and the uid_map check is *more*
relevant (now has to assert `1000 1000 1` for keep-id rather than `0 1000 1`).

### 3.7 Missing risks

- **`seccomp.json` interaction:** the profile has `clone3 → ENOSYS` and
  `unshare(CLONE_NEWUSER)` blocked. Podman's runtime applies its own default
  seccomp on top; need `--security-opt seccomp=unconfined` first to confirm
  Podman's userns operations don't trip the filter. (Macolima had to deal with
  this.)
- **Dockerfile-purge invariants:** no `bubblewrap`, no `socat`, no
  `openssh-client`. Need to be carried forward verbatim — plan doesn't mention.
- **Resource limits:** `pids_limit`, `mem_limit`, `cpus`, `ulimits` — Podman
  supports them but compose-dialect handling differs between `podman-compose`
  (Python shim) and `podman compose` (native). Plan doesn't say which.
- **`.trivyignore.yaml`:** the DS-0002 finding goes away (good) but Podman
  images can produce a couple of new "USER directive in last stage" *style*
  findings depending on scanner version.

### 3.8 What it doesn't mention at all: idmapped mounts

**`idmapped mounts`** are a way to get non-root containers under rootless
Docker without switching engines (Linux ≥5.12, runc supports it, compose
support landing). This is the actual long-term answer. Skipping it means the
plan locks us into a Podman migration when a simpler path is plausibly 12-18
months out via Docker.

---

## 4. Costs of the migration as written

To make this plan real:

1. **Working WSL2 + Podman + GPU proof of concept** — 1–2 days of fiddling,
   possibly blocked by Podman version availability and CDI/dxg incompatibility.
2. **Path-rewrite sweep** across `Dockerfile`, `docker-compose.yml`,
   `init-profile-state.sh`, and `config/` for `/root/` → `/home/agent/`.
3. **Re-run of `verify-sandbox.sh`** (with updated `1000 1000 1` map check).
4. **Re-run of `trivy-scan.sh`** to check for new findings.
5. **Updated `.devcontainer/` host-side wiring** (correct VS Code setting
   location).
6. **Macolima-divergence decision:** macolima is rootful Docker inside Lima,
   so it'd no longer share an architectural model with windows-ai-sandbox
   (cross-repo doc sync becomes harder).

---

## 5. Recommendation

**Don't migrate now.**

- **Today:** add the `DS-0002` ignore to `.trivyignore.yaml` with the rationale
  that the userns boundary is what makes "container root" safe, and the
  `uid_map` runtime check in `verify-sandbox.sh` enforces it.
- **Tracking note:** revisit non-root container when either:
  1. Docker compose ships idmapped-mount support (lets us get there without
     changing engines), or
  2. macolima migrates to Podman first and we can copy the working pattern.
- **If Podman migration becomes mandatory anyway** (e.g. compliance pressure):
  treat the gemini plan as a checklist outline, not a design. Sections 3.1
  (Podman version), 3.2 (GPU on WSL2), 3.3 (path sweep), 3.5 (VS Code wiring),
  and 3.7 (seccomp/purge invariants) all need real engineering before the plan
  is executable.
