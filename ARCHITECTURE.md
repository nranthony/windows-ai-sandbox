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
      ├─ postgres-<profile>      (opt-in via COMPOSE_PROFILES=db-postgres)
      └─ mongo-<profile>         (opt-in via COMPOSE_PROFILES=db-mongo)
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
  `extra_hosts` with static IPs (`egress-proxy` .10, `postgres` .20, `mongo` .30).
  This closes the DNS-exfil side channel that `internal: true` alone does NOT close.
- Removing `internal: true` turns the proxy into a suggestion. Never do it.

## Per-profile persistent state (outlives container recreates)

```
~/.ai-sandbox/profiles/<profile>/
├── claude-home/       → /root/.claude           (sessions, settings, credentials, MCP)
├── claude.json        → /root/.claude.json      (single-file bind; seeded '{}' on first up)
├── cache/             → /root/.cache            (npm, uv, pip caches)
├── config/            → /root/.config           (gh/, glab-cli/, git/config)
├── gemini-home/       → /root/.gemini           (Antigravity CLI `agy` home)
├── kaggle/            → /root/.kaggle           (kaggle.json, chmod 600; optional — egress gated by [kaggle] allowlist)
├── subnet-octet       (this profile's 172.30.<octet>.0/24 allocation)
└── db.env             (optional; postgres/mongo credentials — see
                        sandbox_templates/common/db.env.template)
```

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
| Agent tools | `sandbox_templates/claude/claude-settings.json` deny-lists Claude's Bash/Read tools (network clients, git write ops, package installs, secrets reads — **the JSON file is the authoritative list**, don't trust prose mirrors); `deny-destructive.sh` PreToolUse hook closes the bypass class |
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
│   ├── common/                   #   dotfiles, db.env.template, pdf-styles/
│   ├── claude/                   #   claude-settings.json, hooks/ (deny-destructive)
│   └── skills/                   #   sandbox-side skills (audit-sandbox tier-3)
├── proxy/                        # squid.conf + allowed_domains.txt (egress allowlist)
├── scripts/                      # profile.sh (lifecycle driver), verify/audit, with-egress, ephemeral
├── docs/                         # Design notes, permissions model, portability, debug recipes (index.md)
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
