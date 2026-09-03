# 0023 — Ollama sibling container (local LLM inference on sandbox-internal)

**Status: Accepted 2026-09-03** — decision gates §7 closed by the owner's
"implement" on the branch `feat/0023-ollama-sibling`; implementation per
[plan.md](plan.md). Revised the same day against the research in §8 (Claude
Code's own backend switch), which changed the item's shape: the agent side is
three environment variables, not a new CLI.

**Touches:** `docker-compose.yml` (service, `extra_hosts`, `NO_PROXY`),
`docker-compose.wsl-gpu.yml` (GPU overlay for the sibling), `scripts/profile.sh`
(compose-profile handling, `ollama` subcommand, `health`), `scripts/init-profile-state.sh`,
`scripts/verify-sandbox.sh` (backend + reachability check),
`sandbox_templates/common/secrets.env.template` (the backend switch),
`ARCHITECTURE.md`, `AGENTS.md`, `.agents/skills/profile-lifecycle.md`,
`docs/index.md`. Per AGENTS.md every commit states the security impact and
`just test-offline` + `profile.sh <p> verify` must pass.

---

## 1. Context & Motivation

Local inference (Qwen, Llama, DeepSeek, gpt-oss) next to the agent stack gives
tool calling, embeddings, completion and reasoning with no external API call —
and, since Ollama v0.14.0 (January 2026) speaks the Anthropic Messages API,
**Claude Code itself can run against it** (§8). That is the reason the item
exists in this form: the harness the sandbox already guards — deny lists, the
hook engine, seccomp, policy convergence — stays in place while the model
underneath changes. A separate CLI for "other models" ([0009](../0009-the-third-cli-runs-on-bun/spec.md))
is not needed for that goal.

Placing Ollama inside `ai-sandbox-<profile>` would conflate inference with
workspace execution and bloat the shared image. Like `postgres`, `mongo` and
`egress-proxy`, it is a **sibling service**, per profile.

## 2. Invariants & Security Boundaries

1. **Air-gapped runtime.** The running Ollama container has zero outbound
   reach: `sandbox-internal` only (`internal: true`), no proxy variables, no
   published port. It cannot phone home, pull at runtime, or exfiltrate.
2. **One interface.** Reachable only from the profile's agent, at
   `ollama:11434`, over the profile's own internal network.
3. **Per profile, never shared.** A shared instance would have to join every
   profile's internal network — a multi-homed container bridging networks that
   are isolated by design, on which postgres/mongo run without auth. Same
   argument that keeps `egress-proxy` per profile. Storage is shared (§5);
   the *process* is not.
4. **The model store is read-only to the runtime** (D4). Ollama's API includes
   create, delete, copy and blob upload. With a shared *writable* store, profile
   A can plant a Modelfile whose system prompt profile B then runs — a
   cross-profile injection channel that exists even with separate instances.
   Ingest happens only through the host-side helper (§5.3).
5. **Substrate neutral base** (Golden Rule 2). GPU wiring lives only in
   `docker-compose.wsl-gpu.yml`.
6. **Durable model placement.** Weights are large data: host bind mount,
   gitignored territory (`~/.ai-sandbox/`), survives `docker rm`.
7. **Hardened like the other siblings.** `cap_drop: ALL`, `no-new-privileges`,
   `read_only: true` rootfs with tmpfs for what Ollama must write, `pids_limit`,
   memory cap, digest-pinned image, `restart: "no"`. Docker's default seccomp
   (not `seccomp.json`): the strict profile is unmeasured against Ollama's
   runner and `creat`/`io_uring` are plausible casualties — a follow-up, not a
   silent widening.

## 3. Network Architecture

### 3.1 Attachment
`ollama` joins **only** `sandbox-internal`, pinned at `172.30.${SANDBOX_OCTET:-0}.40`.
No default gateway to any external bridge, so no outbound path at all.

### 3.2 Name resolution
The agent's DNS is sinkholed (`dns: [127.0.0.1]`); `ollama` is added to the
agent's `extra_hosts` beside `egress-proxy`/`postgres`/`mongo`, driven by the
same `SANDBOX_OCTET` so pin and name cannot drift.

### 3.3 Proxy bypass
The agent forces all HTTP through Squid. `ollama` is added to `NO_PROXY` /
`no_proxy` so `http://ollama:11434` goes direct. Postgres/mongo never needed
this (not HTTP); Ollama is the first HTTP sibling.

## 4. Substrate Separation

### 4.1 Base (`docker-compose.yml`)
Service `ollama`, `container_name: ollama-${PROFILE}`, `profiles: ["ollama"]`,
image pinned by index digest (`ollama/ollama:latest@sha256:32931b46…`, read
2026-09-03 with `docker buildx imagetools inspect`; refresh recipe in the
compose comment). Mounts: `${HOME}/.ai-sandbox/models/ollama:/models:ro`
with `OLLAMA_MODELS=/models`; tmpfs on `/root/.ollama` (Ollama writes an
`id_ed25519` key pair there at start) and `/tmp`. `OLLAMA_HOST=0.0.0.0:11434`.
No `OLLAMA_KEEP_ALIVE` override (D5).

### 4.2 WSL2 overlay (`docker-compose.wsl-gpu.yml`)
Same three lines the agent gets: `/dev/dxg`, `/usr/lib/wsl:ro`,
`LD_LIBRARY_PATH=/usr/lib/wsl/lib`. Layered by `profile.sh` on `/dev/dxg`;
bare Linux runs CPU-only from the base file. Whether Ollama's runner finds
`libcuda.so.1` via that path is a Phase 4 measurement, not an assumption.

## 5. Model Storage & Ingestion (offline by design)

### 5.1 Host layout — shared across profiles (D1)
```
~/.ai-sandbox/models/ollama/        ← mounted :ro at /models in every ollama-<p>
├── manifests/                      (Ollama's own layout — OLLAMA_MODELS root)
├── blobs/
└── pull.log                        (one line per host-side pull: date, model, digest)
```
Shared to avoid duplicating multi-GB blobs per profile. Safe to share ONLY
because the runtime mount is read-only (§2.4).

### 5.2 Ingest path — `scripts/profile.sh <p> ollama pull <model>` (D3, D7)
A `--rm` container from the same pinned image, the store mounted `rw`, on
Docker's **default bridge** — a host-side operator action outside the sandbox
boundary, the same class as `docker pull` of an image. The agent cannot invoke
it (no docker socket in the container). Ollama verifies every blob against the
registry manifest digest on pull. The helper appends to `pull.log`.

Routing the pull through the profile's Squid was considered and rejected for
now: `registry.ollama.ai` redirects blob fetches to CDN hosts that would have
to be OBSERVED and allowlisted (the `[pytorch]` lesson in 0016), for a path
the agent never uses. Re-open if a pull is ever wanted from *inside* a profile.

### 5.3 Custom GGUF / Modelfile
`ollama pull` covers the registry. A local GGUF goes in via the same helper
with `create <name> -f <Modelfile>` — also host-side, also into the shared
store. No workspace path is ever writable by the runtime.

## 6. Lifecycle (`scripts/profile.sh`)

- The persisted `compose-profiles` file becomes a **comma-separated list**
  (`db-postgres,ollama`), which is what `COMPOSE_PROFILES` already accepts.
  `db enable|disable` edits only the `db-*` token; `ollama enable|disable`
  edits only the `ollama` token. Neither touches the other's.
- `ollama status` reports the persisted default and the container state.
- `health` treats `ollama-<p>` like a DB sibling: expected when persisted,
  orphan-flagged when running unpersisted.
- `docker-gc.sh` needs nothing: images are report-only there already.

## 7. Decision Gates — all closed 2026-09-03

| | Decision | Taken |
|---|---|---|
| D1 | Storage scope | **Shared** `~/.ai-sandbox/models/ollama`, made safe by D4 |
| D2 | Host port | **Internal only.** Loopback publish left commented, mirroring postgres/mongo |
| D3 | Helper CLI | **Yes** — `ollama pull|create|list` under `profile.sh` |
| D4 | Runtime mount mode | **Read-only** (§2.4). New: came from the 2026-09-02 review |
| D5 | Keep-alive | **Ollama default (5m)**, not 24h. 12 GB VRAM, one card; an idle profile must release it |
| D6 | Claude Code backend switch | **Per profile, via `secrets.env`** (§8). The settings template's `env` block is sandbox-owned and overwritten on `up` (ADR-0007), so the switch cannot live there; `env_file` is per profile and read at create. `verify` prints which backend the profile is on |
| D7 | Pull network | **Default bridge, host-side** (§5.2) |

## 8. Claude Code against Ollama / OpenRouter — what the research established

Grounded 2026-09-02 (sources in the session; the durable ones are the vendor
docs). **Claude Code has an official "LLM gateway" path**: `ANTHROPIC_BASE_URL`
to any host speaking the Messages API, `ANTHROPIC_AUTH_TOKEN` as the bearer,
`ANTHROPIC_API_KEY` explicitly empty, aliases pinned via
`ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL`. Neither Ollama nor OpenRouter is
named in Anthropic's docs; both vendors document the recipe themselves.

- **Ollama** ≥ 0.14.0: `ANTHROPIC_BASE_URL=http://ollama:11434`,
  `ANTHROPIC_AUTH_TOKEN=ollama`. Recommends `qwen3-coder` / `gpt-oss:20b`,
  ≥32K context (64K for large repos). Lists tool calling, thinking and vision
  as supported. **Open issue ollama/ollama#13949** (Jan 2026): Claude Code
  calls `/v1/messages/count_tokens`, Ollama 404s, and the server was reported
  to wedge afterwards. **Measured 2026-09-03 on 0.33.3: still 404, no wedge;
  `claude -p` completed four `/v1/messages` round-trips** ([notes.md](notes.md)).
- **OpenRouter**: `ANTHROPIC_BASE_URL=https://openrouter.ai/api`, key as the
  auth token. `openrouter.ai` is already live in the allowlist; nothing to
  open. OpenRouter's own caveat: Claude Code is optimised for Anthropic models.
- **Documented consequences of a non-first-party base URL**: MCP tool search
  off by default, Remote Control and server-managed settings unavailable,
  model IDs passed through unvalidated. Community measurements put local-model
  edit accuracy around 70–80 % against ~98 % for Sonnet.
- **What does NOT change**: every control here is on the harness, not the
  model — deny lists, the hook engine, seccomp, egress. That is the whole case
  for this route over a third CLI.

Consequence for **0009**: if opencode was wanted for model choice, this covers
it with zero new attack surface; 0009 stays parked and its motivation is
narrowed to "the opencode harness itself" (recorded in `work/README.md`).

## 9. Out of scope

- A shared or host-side Ollama (rejected, §2.3).
- Running the sibling under `seccomp.json` (follow-up after measurement).
- `agy` against Ollama — Antigravity has no documented base-URL switch.
- Any always-on egress: the allowlist is unchanged by this item.

**Exit rule:** archive this folder to `docs/_archive/` when the branch merges.
