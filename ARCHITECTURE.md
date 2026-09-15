# Architecture

System map for the sandbox stack. Agent conventions live in [AGENTS.md](AGENTS.md);
operational how-tos live in [.agents/skills/](.agents/skills/).

## Two substrates, one stack

The same compose stack runs on two host substrates, auto-detected by
`scripts/profile.sh` (the signal is `/dev/dxg`, which exists only under WSL2
with GPU paravirtualization; override with `SANDBOX_GPU=0|1`):

```
Substrate A — Windows + WSL2 (GPU)            Substrate B — bare Ubuntu Linux
─────────────────────────────────            ───────────────────────────────
Windows OS                                    Ubuntu 24.04 host
  └─ WSL2 Ubuntu 24.04                          └─ rootless Docker
      └─ rootless Docker                            └─ [same stack, no GPU
          └─ stack + docker-compose.wsl-gpu.yml         overlay — base
             overlay (/dev/dxg, /usr/lib/wsl,           docker-compose.yml only]
             LD_LIBRARY_PATH)
```

Per profile (both substrates):

```
rootless Docker (userns: container UID 0 ↔ host UID 1000)
  ├─ windows-ai-sandbox:latest   (shared image: CUDA + claude + agy + bd + gh + glab + just + uv + zsh)
  └─ per profile:
      ├─ ai-sandbox-<profile>    (agent; /workspace = ~/repo/<profile>/)
      ├─ egress-proxy-<profile>  (Squid; domain allowlist is the only way out)
      ├─ postgres-<profile>      (opt-in via `profile.sh <p> db enable postgres`)
      ├─ mongo-<profile>         (opt-in via `profile.sh <p> db enable mongo`)
      └─ ollama-<profile>        (opt-in via `profile.sh <p> ollama enable`; local
                                  inference, sandbox-internal only, no egress at all)
```

The security boundary is identical on both substrates: it is a property of
**rootless Docker**, not of WSL. A full container escape lands as an
unprivileged host user (UID 1000), never root. Rootful Docker is NOT an
equivalent substrate — see `docs/portability-assessment-plan.md`.

## Network model (load-bearing)

See `sandbox-hardening-package.md` §4 and `docs/compose-network-ipam.md`.

- `sandbox-internal` (internal: true, IPAM `172.30.${SANDBOX_OCTET}.0/24` —
  per-profile octet allocated by `profile.sh`) — agent-only, no direct internet.
- `sandbox-external` — Squid's outbound side only.
- DNS sinkholed (`dns: [127.0.0.1]`) on the agent; internal names resolved via
  `extra_hosts` with static IPs (`egress-proxy` .10, `postgres` .20, `mongo` .30,
  `ollama` .40 — the first HTTP sibling, so it is also in the agent's `NO_PROXY`,
  reached direct at `http://ollama:11434` rather than through Squid).
  This closes the DNS-exfil side channel that `internal: true` alone does NOT close.
- Removing `internal: true` turns the proxy into a suggestion. Never do it.
- **`proxy/` is bind-mounted as a DIRECTORY** (`./proxy:/etc/squid/host:ro`), not
  as two files. A single-file bind mount resolves to an inode at container start,
  so any write that *replaces* the file — `git checkout`/`merge`/`pull`/`stash`,
  an editor's atomic save, `sed -i` — leaves the running proxy bound to the old,
  deleted inode. It then cannot see host edits at all, and `squid -k reconfigure`
  re-reads the stale copy and exits 0. That made the repo's allowlist *advisory*:
  tightening it in git did not take effect on a running proxy (measured twice —
  G9, and again on a comment-only merge). A directory mount resolves the path on
  every `open()`, so the class is gone. Never revert it to a file mount; `verify`
  fails loudly if you do, and the mount target is duplicated in
  `proxy/squid.conf`'s `acl` plus three script constants that all fail *silently*
  on a mismatch (`scripts/with-egress.test.sh` locks them together).

## Per-profile persistent state (outlives container recreates)

```
~/.ai-sandbox/profiles/<profile>/
├── claude-home/       → /root/.claude           (sessions, settings, credentials, MCP)
│   ├── settings.json                         (env/hooks/permissions/sandbox are SANDBOX-OWNED and
│   │                                          OVERWRITTEN from the template on up; ADR-0007)
│   ├── settings.discarded.json               (what the last overwrite dropped — recovery capture,
│   │                                          agent-writable, NOT audit evidence)
│   └── skills/                               (MIRRORED from sandbox_templates/skills/; ADR-0005)
├── claude.json        → /root/.claude.json      (single-file bind; seeded '{}' on first up)
├── cache/             → /root/.cache            (npm, uv, pip caches)
├── config/            → /root/.config           (gh/, glab-cli/, git/config, pnpm/rc)
├── gemini-home/       → /root/.gemini           (Antigravity CLI `agy` home)
│   ├── config/hooks.json                     (sandbox guardrail registration — REPLACED on up)
│   ├── config/{config,mcp_config}.json,      (live agy state sharing that dir; convergence is
│   │   projects/, .migrated                   file-scoped, NEVER an ADR-0005 mirror, or these go)
│   └── antigravity-cli/settings.json         (agy's own prefs AND our permissions/toolPermission —
│                                              MERGED on up, never overwritten; ADR-0006/0007)
├── kaggle/            → /root/.kaggle           (kaggle.json, chmod 600; optional — egress gated by [kaggle] allowlist)
├── audit/             (depgate.jsonl — one JSON line per with-egress.sh install
│                       window: bracket, egress hosts, lockfile + module delta.
│                       NOT mounted into any container; the proxy's own
│                       access.log is tmpfs and dies with it)
├── subnet-octet       (this profile's 172.30.<octet>.0/24 allocation)
├── db.env             (optional; postgres/mongo credentials — see
│                       sandbox_templates/common/db.env.template)
├── secrets.env        (optional; operator-owned API keys, chmod 600, never rewritten by a script)
└── backend.env        (optional; MANAGED by `profile.sh <p> backend` — the Claude Code
                        endpoint switch, injected after secrets.env; absent = Anthropic API)
```

Not per profile — one store, shared by every profile's Ollama sibling:

```
~/.ai-sandbox/models/ollama/     (manifests/, blobs/, pull.log — OLLAMA_MODELS root)
```

Mounted **read-only** at `/models` in every `ollama-<profile>`, and written only
by the host-side helper (`profile.sh <p> ollama pull|create|rm`), which runs a
`--rm` container outside the sandbox boundary. Read-only is the reason sharing is
safe: Ollama's API has create/delete/copy/blob-upload, so a shared *writable*
store would let profile A plant a Modelfile system prompt that profile B then
runs. Weights are large data — host bind mount, survives `docker rm`.

## Security posture

| Layer | Control |
|---|---|
| User namespace | Rootless Docker; container UID 0 maps to host UID 1000 (NOT root) |
| Syscalls | `seccomp=./seccomp.json` (mode 2) — `clone3→ENOSYS`, no user-namespace nesting |
| Capabilities | `cap_drop: ALL` |
| Privilege escalation | `no-new-privileges:true` |
| Resources | `pids_limit: 4096`, `mem_limit: 20g`, `cpus: 4` (WSL: needs `memory=48GB` in `win_setup/.wslconfig`) |
| Filesystem | rootfs rw (non-root userns + cap_drop is the boundary); `/tmp` + `/run` + `/root/.{npm-global,local}` tmpfs `noexec,nosuid,nodev` |
| Network | internal-only agent net + Squid allowlist sidecar (see above) |
| DNS | sinkholed + `extra_hosts` |
| Agent tools | `sandbox_templates/claude/claude-settings.json` deny-lists Claude's Bash/Read tools (network clients, git write ops, package installs, secrets reads — **the JSON file is the authoritative list**, don't trust prose mirrors); `deny-destructive.sh` PreToolUse hook closes the bypass class. The policy file **converges on every `up`** and tier-1 `verify` reports drift on the owned keys ([ADR-0007](docs/adr/0007-policy-templates-are-source-of-truth-for-every-agent.md)); the hook ENGINE reaches a container through the image instead, so it still needs `build` + recreate — different routes, and that difference is the recurring confusion |
| Agent tools (`agy`) | `sandbox_templates/antigravity/antigravity-settings.json` carries the same deny set in agy's `command(...)` grammar, diffed against Claude's by `agent-policy.test.sh`. The **static** list is the load-bearing layer here: a workspace `.agents/hooks.json` outranks the global hook and can disable it by name (measured), while nothing in a workspace reaches `settings.json`. Same hook engine, `--dialect=antigravity`, fail-CLOSED. [ADR-0006](docs/adr/0006-antigravity-is-two-layer-like-claude.md) |
| Dependencies | Registries **unreachable by default** ([ADR-0003](docs/adr/0003-strict-egress-default.md)); installs go through `scripts/with-egress.sh`, which pre-flights named packages against OSV, refuses to open on a live `MAL-` record, and appends an audit record per window. Resolution is quarantined — `min-release-age=7` (npm, `/usr/etc/npmrc`) and `minimum-release-age=10080` min (pnpm), so nothing published this week resolves. Install scripts blocked (`allow-scripts` empty; pnpm 10 blocks by default). Python is **wheels-only** ([ADR-0004](docs/adr/0004-python-wheels-only.md)) — `no-build=true` in `/etc/uv/uv.toml` and `only-binary=:all:` in `/etc/pip.conf`, since an sdist runs `setup.py` at install time; both are set because uv reads no pip config. `verify` asserts all of it; drift fails |
| Vendored tools | `myclickup` (private ClickUp CLI) is installed from a wheel vendored into `sandbox_templates/wheels/` by `scripts/vendor-tools.sh` from the depot channel (ADR-0014) — zero runtime deps, so no build-time network and nothing an agent could be asked to repair in a container where every installer is denied. The payload is **gitignored** (this repo public, that one private, and a `py3-none-any` wheel is a zip of its source), so the `Dockerfile` copies the *directory* and installs conditionally: a clone without the payload builds fine and simply has no `myclickup`. Its agent skill ships with the wheel, not hand-copied, so it cannot describe a version the image doesn't have. Permission posture: the 18 reads allowed; of the 11 writes (0.7.0), three — `comment`/`set-status`/`update` — were promoted to `allow` by owner sign-off on 2026-08-24 and the other eight prompt ([docs/permissions-model.md](docs/permissions-model.md)) |
| Vendored tools (with deps) | `paperbridge` (public literature CLI) is the second channel payload and the **first with runtime dependencies**, so it breaks the invariant the row above rests on. Same door (`vendor-tools.sh`, same conditional `Dockerfile` block, same refusal on two wheels), but its resolution happens at build time: `uv tool install` re-resolves from PyPI and never reads the producer's lock, so the graph is PINNED by a generated `sandbox_templates/wheels-host/paperbridge-constraints.txt` and the build asserts the installed graph rather than trusting its own exit code — unpinned, `bibtexparser>=1.4` resolves to 2.0.0, the build goes green and BibTeX breaks at runtime. Two of its transitive packages publish sdists only, so they are built host-side and supplied via `--find-links` rather than weakening Gate 3. Its skill IS tracked (the repo is public); the wheels are not. Permission posture: 20 reads allowed — including `download`/`export`, which write files unprompted but are fenced by the tool's own 12-host download allowlist, of which this sandbox's egress is a strict superset — and all 8 Zotero writes prompt, with `zotero-delete` additionally carrying a `force_ask` hook rule because agy caches a plain `ask` as permanent (work/0026) |
| GPU (WSL only) | `docker-compose.wsl-gpu.yml` overlay — `/dev/dxg` + `/usr/lib/wsl`; auto-layered on detection |
| Restart policy | `restart: "no"` — explicit `up` after host reboot (prevents silent config-drift recovery) |

Deliberately NOT installed in the image: `bubblewrap`, `socat`,
`openssh-client` (`sandbox-hardening-package.md` §7).

## Repository map

```
├── AGENTS.md                     # Agent conventions (source of truth; CLAUDE.md is generated)
├── ARCHITECTURE.md               # This file
├── Dockerfile                    # Shared image (CUDA 12.6.3 base, digest-pinned; AI CLIs in tail layer)
├── docker-compose.yml            # Base stack — substrate-neutral, NO GPU/WSL wiring
├── docker-compose.wsl-gpu.yml    # WSL2 GPU overlay (auto-layered by profile.sh)
├── justfile                      # Optional front door; thin pass-throughs to profile.sh/setup.sh
├── seccomp.json                  # Syscall filter
├── .trivyignore.yaml             # Accepted CVEs/misconfigs with expiries
├── .agents/skills/               # Host-agent operational guides
├── sandbox_templates/            # Assets injected into sandboxes
│   ├── common/                   #   dotfiles, db.env.template, secrets.env.template, pdf-styles/
│   ├── bin/                      #   webfetch (web-read broker; peer backends, no default; baked to /usr/local/bin)
│   ├── claude/                   #   claude-settings.json, hooks/ (deny-destructive — shared engine)
│   ├── antigravity/              #   hooks.json + antigravity-settings.json (agy policy; ADR-0006)
│   ├── skills/                   #   sandbox-side skills (audit-sandbox tier-3); some vendored — UPSTREAM.md
│   ├── wheels/                   #   vendored channel wheels — GITIGNORED payload, .gitkeep only
│   └── wheels-host/              #   pins + host-built wheels for sdist-only deps (work/0026);
│                                 #   *.whl gitignored, constraints + SHA256SUMS tracked
├── proxy/                        # squid.conf + allowed_domains.txt (egress allowlist)
├── scripts/                      # profile.sh (lifecycle driver), verify/audit, with-egress, ephemeral
│   ├── vendor-tools.sh          #   consumes the depot channel into the build context (wheel, skills, plugins)
│   ├── depaudit.py               #   dependency posture scanner + OSV MAL- check (host-side, stdlib-only)
│   ├── depaudit.test.sh          #   its regression suite — 43 offline, --online adds the OSV corpus
│   └── webfetch.test.sh          #   broker suite — 90 offline; hosts↔allowlist, keys never in URLs, no default backend
├── docs/                         # Design notes, permissions model, portability, debug recipes (index.md)
│   ├── adr/                      #   Decisions — append-only, superseded not deleted (ADR-0001)
│   └── incoming/                 #   Raw unprocessed input — triage out, don't accumulate
├── work/                         # In-flight implementation plans + proposals (spec.md) — ARCHIVED on merge (ADR-0010)
├── host_setup/                   # Rootless-Docker host setup (WSL2 or bare Linux; run once)
├── dashboard/                    # Host-side Streamlit control console (own AGENTS.md)
├── container_testing/            # CUDA/PyTorch smoke-test uv project (own AGENTS.md)
├── win_setup/                    # Windows .wslconfig (WSL substrate only)
├── reports/                      # Docker-bench audit reports
└── archived_script_ref/          # Deprecated material (do not treat as current)
```

## Substrate-specific notes

**WSL2 (Substrate A):**
- Always `code .` from inside WSL Ubuntu, never from Windows (rootful Docker takeover risk).
- GPU: CUDA 12.6.3 needs NVIDIA driver ≥530.30.02 on Windows. Passthrough is
  `/dev/dxg` + `/usr/lib/wsl`, NOT `--gpus all` (broken under NVIDIA Container
  Toolkit ≥1.18; toolkit pinned 1.17.8-1 in host setup).
- GPU tooling is agent-visible by design: `/usr/lib/wsl/lib` is appended to
  `PATH` (`Dockerfile`) and `Bash(nvidia-smi:*)` is allow-listed
  (`sandbox_templates/claude/claude-settings.json`), so `nvidia-smi` runs
  unprompted. Both are load-bearing against a specific failure: without them a
  bare `nvidia-smi` is "command not found" and agents report the GPU as absent
  while it works. Rationale + the CUDA version model live in the GPU bullets of
  `sandbox_templates/common/agent-notice.md`.
- Three CUDA versions coexist and are NOT expected to match: the driver/UMD from
  the Windows host (`/usr/lib/wsl/lib/libcuda.so.1`), the image's `libcudart`
  (`CUDA_VERSION`, `-base` — no `nvcc`/cuDNN/cuBLAS), and each project's venv
  runtime from its torch wheel index (`.venv-sandbox` in the container,
  [ADR-0013](docs/adr/0013-the-environment-names-the-venv.md)). Only driver ≥ runtime must hold. Retarget
  CUDA per project via its `pyproject.toml` wheel index, not via the image.
  `LD_LIBRARY_PATH=/usr/lib/wsl/lib` (set in the overlay) is what makes the host
  driver win over the image's `cuda-compat-*` shim — do not reorder it.
- D-Bus race on WSL restart handled by the kickstart block in `~/.zprofile`/`~/.profile`.

**Bare Linux (Substrate B):**
- No GPU overlay: `torch.cuda.is_available()` → `False` is expected, not a failure.
- Host setup auto-skips all NVIDIA steps (`SETUP_GPU=0|1` overrides).
- Tier-1/2 verification reports GPU checks as `N/A`, not warnings.

**Both:**
- Rootless Docker socket: `/run/user/1000/docker.sock`.
- Container runs as **root inside** — correct by design (remaps to host 1000).
  Flipping to non-root inside would remap to host UID 100999 and break workspace writes.
- uv at `/usr/local/bin/uv`; default venv `/root/.venv` (Python 3.12). Node.js 24.
- Forwarded ports: 8080, 8501, 8188.
- VS Code attaches to the already-running container (**Attach to Running
  Container**); there is no `.devcontainer/`. Required host settings
  (`remote.SSH.enableAgentForwarding: false`, `dev.containers.copyGitConfig:
  false`) and the leakage analysis: `docs/vscode-integration-security.md`.
