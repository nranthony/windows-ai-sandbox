# 0013 — Reaching an in-container agent from another device on the LAN

**Status:** Not started — captured 2026-08-24 from an owner-supplied external
note; Buzz assessed against the upstream repo the same day (§3.5). **Parked
behind the gates in §5** — owner deferred on 2026-08-25 without answering D1a;
the likely outcome is *resolve* (SSH + `attach`, one doc paragraph, archive)
with Buzz becoming an RFC draft only if wanted, but that is the owner's call. The source note's mechanism does not exist (§2); the
*goal* behind it does, and that is what this item scopes.

**Exit rule:** delete this folder, or move to [`docs/_archive/`](../../docs/_archive/),
when the work merges.

---

## 1. The want

Drive a Claude Code session that runs **inside** a profile container from a
second device on the home network (phone, tablet, laptop) — not by sitting at
the WSL2/Linux host and running `scripts/profile.sh <p> attach`.

That is a real gap. Every current entry point is host-local by design: `attach`
is a TTY on the host, and the dashboard binds `127.0.0.1` because it is "an ops
tool, not a service" (`dashboard/AGENTS.md`).

## 2. Corrections to the source note — do not implement it as written

The note was an AI-generated recipe. Checked against the installed CLI
(`claude --help`, 2026-08-24) and this repo. Recording the corrections here so
the next reader does not re-derive them:

| Claim in the note | Actual |
|---|---|
| `claude serve --port 8000 --host 0.0.0.0` | **No such subcommand.** The command list is `agents, auth, auto-mode, doctor, gateway, import, install, mcp, plugin, project, setup-token, ultrareview, update`. There is no listener mode and no `--host`/`--port`. |
| "ACP port, usually 8000" | **ACP is a stdio protocol, not a TCP service.** ACP clients spawn the agent as a child process and speak JSON-RPC 2.0 over its stdin/stdout. For Claude that is an adapter package — currently `@agentclientprotocol/claude-agent-acp` (0.70.0, published 2026-08-18); the older `@zed-industries/claude-code-acp` still exists but last shipped 0.16.2 on 2026-02-17 and Buzz calls it the legacy name. Either way it is an adapter, not the CLI. There is no port to `EXPOSE`. |
| `EXPOSE 8000` + `-p 8000:8000` | Publishes nothing useful, and would violate the standing rule: the only ports in `docker-compose.yml` are commented DB examples carrying **"Loopback-only — do not bind 0.0.0.0."** |
| `docker run -d -v ... claude-custom-image` | Violates golden rule 1 — `scripts/profile.sh` is the single lifecycle entry point. It also drops seccomp, the Squid egress gate, the per-profile subnet, and the state layout. |
| `FROM node:20-slim; npm install -g @anthropic-ai/claude-code` | Bypasses the Dockerfile's load-bearing install-layer order (beads < CLIs < npmrc Gate 2 < uv/pip Gate 3) and both age gates. |
| `-e ANTHROPIC_API_KEY="..."` on the command line | Credentials here live in `secrets.env` (0600), never in a shell command or image. |
| "Ensure your local network is secure" as the mitigation | An unauthenticated agent endpoint on the LAN is a remote-code-execution surface with a filesystem mount. "The Wi-Fi has a password" is not a control. |
| "Block Buzz — Settings > Agents > Add Custom Agent" | **Real, and roughly right — but it is not a way to point a client at a port.** Buzz (github.com/block/buzz, Apache-2.0) is a self-hosted Nostr-relay workspace; its desktop app has an Agents settings surface (`desktop/src/app/routes/agents.tsx`), and an agent record carries `agent_command`/`agent_args` (`docs/remote-agents.md`, §System Model). What that field configures is *the ACP command `buzz-acp` spawns on stdio* — the same stdio story as the row above, not an endpoint URL. The owner's actual intent turned out to be running Buzz itself in a container; see §3.5. |

**The one substantive point the note got right:** headless OAuth. Signing an
agent in inside a container means copying the auth URL out of the container
output and completing it in a host browser. That is already how profiles are
signed in here — it is not new work.

## 3. Approaches that do exist

Ordered by how little of the boundary they move. Pick in §5 D2.

1. **SSH to the host, then `attach`.** Nothing in this repo changes. The remote
   device gets a terminal on the host; `scripts/profile.sh <p> attach` runs
   exactly as it does today, with every guarantee intact. The transport is
   authenticated (keys) and the surface is the host's SSH daemon, which is a
   surface the owner already understands. Any decent phone SSH client renders
   the TUI. **This is the recommendation unless D1 rules it out.**
2. **SSH + a mesh VPN (Tailscale/WireGuard) instead of raw LAN.** Same as 1,
   but the endpoint is not reachable from anything that merely joined the
   Wi-Fi, and it works off-network. Costs a daemon on the host, outside the
   sandbox boundary.
3. **An ACP adapter spawned over SSH.** If the owner's client genuinely speaks
   ACP, the honest wiring is client → SSH → adapter-on-stdio → agent, not a TCP
   listener. Still no published port. Needs the adapter vendored through
   `scripts/vendor-tools.sh` (it is an upstream payload entering the image —
   ADR-0014 applies, and it needs a line in `tools-check`).
4. **A published listener inside the profile network.** Only if 1–3 are ruled
   out. This is the expensive one and it is where the whole security section
   below lands.
5. **A relay the agent dials out to (Buzz).** Inverts the problem instead of
   solving it: the remote device talks to a relay, and the agent container
   reaches that relay *outbound*, so no port is published from a profile
   container and §4 never comes due. It is also by far the largest thing to
   stand up, and the agent under it runs with none of this repo's tool-level
   guardrails. Assessed in full in §3.5; decided in D1b.

## 3.5 Buzz-in-a-container: fit assessment

The owner clarified (2026-08-24) that the intent behind the Buzz row in §2 is
not "connect a Buzz client to a port on a profile container" — it is **could
Buzz run inside this sandbox at all**. Read against the upstream repo
(`github.com/block/buzz`, `main`, read 2026-08-24). Each item is marked
**[V]** verified from a named file, or **[I]** inferred.

### What Buzz is

- **[V]** A self-hostable workspace where humans and agents share channels,
  built on a Nostr relay with one immutable event log; Apache-2.0, Block, Inc.
  (`README.md`, `ARCHITECTURE.md`, `VISION.md`).
- **[V]** Rust workspace (~30 crates) + React/Tauri desktop + Flutter mobile +
  a CLI. Local build needs Rust 1.88+, Node 24+, pnpm 10+, or Hermit
  (`README.md`, `Cargo.toml`, `Justfile`).
- **[V]** It is **three things, not one**: a *relay* (server), a *desktop
  client*, and an *agent harness*. They have opposite network shapes and
  conflating them is where the source note went wrong.

### The relay — a server, and it listens

- **[V]** `deploy/compose/compose.yml` runs the relay as
  `ghcr.io/block/buzz:main` with `BUZZ_BIND_ADDR: 0.0.0.0:3000` published as
  `${BUZZ_HTTP_PORT:-3000}:3000`, plus health `8080` and metrics `9102`.
- **[V]** It requires Postgres 17, Redis 7 and MinIO/S3 alongside it
  (same file); `.env.example` carries `RELAY_OWNER_PUBKEY`, a stable
  `BUZZ_RELAY_PRIVATE_KEY`, DB/Redis/S3 secrets and a git-hook HMAC secret.
- **[V]** Auth is Nostr-native: NIP-42/98 Schnorr signing, `BUZZ_REQUIRE_AUTH_TOKEN`
  and `BUZZ_REQUIRE_RELAY_MEMBERSHIP` in the production `.env`
  (`deploy/compose/.env.example`). Unlike an ACP port, the relay **is**
  authenticated — that is a genuine difference from §4's first bullet.
- **[I]** A relay is therefore not a profile-container workload at all. It is a
  *service stack* with its own compose file, three data stores and a published
  port. Standing it up here means either running upstream's compose beside the
  sandbox (outside `scripts/profile.sh` — golden rule 1 does not cover it,
  because it is not a profile) or using a hosted relay.

### The agent harness — outbound-only, which is the interesting part

- **[V]** `buzz-acp` is a **client**: `Buzz Relay ──WS──→ buzz-acp ──stdio──→
  Your Agent` (`crates/buzz-acp/README.md`). It dials the relay
  (`BUZZ_RELAY_URL`, default `ws://localhost:3000`), listens for @mentions,
  and spawns the real agent as a stdio ACP child. **It opens no listening
  socket.**
- **[V]** Supported children: `goose`, `codex-acp`, Claude via
  `@agentclientprotocol/claude-agent-acp`, or upstream's own minimal
  `buzz-agent` (`crates/buzz-acp/README.md`, `crates/buzz-agent/README.md`).
- **[V]** Configuration is entirely environment: `BUZZ_PRIVATE_KEY` (the
  agent's Nostr `nsec` — its identity), `BUZZ_RELAY_URL`,
  `BUZZ_ACP_AGENT_COMMAND`, `BUZZ_ACP_IDLE_TIMEOUT`, `BUZZ_API_TOKEN`, plus
  the model key for whatever child runs (`ANTHROPIC_API_KEY`, …).
- **[V]** Upstream **has** a headless container story: `Dockerfile.sprig` builds
  an Alpine image whose single `sprig` binary is symlinked as `buzz-acp`,
  `buzz-agent`, `buzz-dev-mcp`, `buzz`, `rg`, `tree`,
  `git-credential-nostr`, `git-sign-nostr`; it runs as a non-root `agent` user
  and its entrypoint `exec`s `buzz-acp`. `crates/buzz-backend-kubernetes`
  deploys that image as a bare Pod (`docs/remote-agents.md`).
- **[V]** `docs/remote-agents.md` states the desktop holds **no management
  channel** to a remote agent: relay presence is the only status signal, stop
  is a relay message, and "anything that can set that environment and exec the
  harness — a bash script, a systemd unit, a CI job — is a conforming
  launcher".

### What that does to 0013's question

**[I]** It makes the LAN question *moot for this shape*, and that is the single
most useful finding in this item. A phone talks to the **relay**; the agent
container reaches the relay **outbound**. Nothing is published from a profile
container, `dns: [127.0.0.1]` and the Squid gate stay exactly as they are, and
§4's whole cost list never comes due. Option 4 is not merely undesirable here —
it is unnecessary. The listener moves to the relay, which is a service that was
designed to be one and authenticates its callers.

### Which door would it come through — and none of them are open

- **[V]** `buzz-acp` is a Rust binary. **There is no cargo or rustc in this
  repo's `Dockerfile`** (grepped, 2026-08-24: no match for `cargo` or `rust`).
  Building in-container is not a small change; it is a toolchain plus
  `crates.io`/`static.crates.io`, neither of which is in
  `proxy/allowed_domains.txt`.
- **[V]** `ghcr.io` is not in the allowlist either, so pulling
  `ghcr.io/block/buzz` or a sprig image needs an allowlist edit.
- **[V]** `registry.npmjs.org` is present but **commented out** (line 276,
  under the "temporary lockdown" note) — so even the npm-installed ACP adapters
  (`@agentclientprotocol/claude-agent-acp`, `codex-acp`) only arrive through
  `scripts/with-egress.sh`, under Gate 2 `min-release-age`.
- **[I]** A prebuilt `buzz-acp` binary would be the `scripts/vendor-tools.sh`
  door (ADR-0014): hash-gated, `VENDORED.lock`, a line in `tools-check`.
  **Unverified** whether upstream publishes a standalone linux `buzz-acp`
  release asset at all — the releases page advertises desktop packages
  (macOS/Linux/Windows) and the pipeline publishes the `ghcr.io` image.
- **[I]** Running upstream's *sprig* image directly is the least work and the
  worst fit: it is a second image, so it inherits none of `docker-compose.yml`'s
  hardening, `seccomp.json`, the per-profile subnet, or the state layout —
  precisely the §2 `docker run` objection wearing a different hat.

### Guardrails — this is the blunt part

- **[V]** This repo's two-layer policy is Claude-Code-shaped and `agy`-shaped:
  `permissions.deny` in `sandbox_templates/claude/claude-settings.json` /
  `sandbox_templates/antigravity/`, plus the `PreToolUse` hook engine
  (ADR-0006, ADR-0007).
- **[I]** **None of it reaches a Buzz agent.** `claude-agent-acp` wraps the
  Claude *Agent SDK*, not the Claude Code CLI, so neither the settings file nor
  the hook engine is in the path. `goose` and `buzz-agent` have no equivalent
  layer seeded here at all — `buzz-agent` runs an unmediated
  LLM→MCP-tool-call loop (`crates/buzz-agent/README.md`).
- **[V]** Buzz's own control is **identity-scoped, not tool-scoped**: each agent
  gets its own keypair, relay membership and signed audit trail
  (`crates/buzz-acp/README.md`, `docs/remote-agents.md`). That is a real
  property and a good one — it answers *who did this*. It does not answer
  *may this delete the branch*, which is what the deny list and the three-tier
  hook exist for.
- **[I]** So the honest summary: **Buzz would run in this sandbox, and it would
  run with none of the controls this repo exists for.** The seccomp profile,
  rootless boundary and Squid gate would still hold — those are container-level
  and agent-agnostic. Everything above them would not. Closing that gap means a
  third dialect in `deny-destructive.test.sh` and a policy template for
  whichever child agent is chosen, which is a work item of its own, not a
  footnote to this one.
- **[I]** One thing that gets *worse*, not better: a relay-driven agent is
  triggered by an @mention from any relay member. The §4 bullet about `ask`
  re-prompting "someone who is present" applies in full, and `agy`'s
  Always-Allow caching hazard with it. Nobody is at the keyboard.

## 4. What option 4 would actually cost

Written down so the trade is visible, not to endorse it. If a listener is ever
published from a profile container:

- **Authentication is mandatory and does not exist.** Nothing in the ACP story
  authenticates a caller. Anything that reaches the port drives an agent that
  can read and write `/workspace` and run `Bash`. Fronting it with mTLS or an
  authenticating reverse proxy is the *minimum*, and that proxy becomes a new
  security-sensitive file.
- **It inverts the egress model.** ADR-0003 makes Squid the only route out.
  A published listener is a route *in*, which the threat model has never had.
  The per-profile subnet allocation and `dns: [127.0.0.1]` sinkhole assume
  outbound-only.
- **The guardrails were sized for a human at the keyboard.** The three-tier
  hook (warn/ask/deny) leans on `ask` re-prompting *someone who is present*.
  A remote caller changes who answers that prompt — and on `agy` a plain `ask`
  caches as a permanent Always-Allow grant, which is exactly why `force_ask`
  exists. Re-examine both tiers before any remote driver is real.
- **It needs an ADR.** Security boundary + public contract → ADR-0001 tier.
- Touching `docker-compose.yml` puts it on the security-sensitive list:
  commit message states the impact, `verify` (tier 1) and `audit` (tier 2)
  both run, ARCHITECTURE.md and `sandbox-hardening-package.md` updated.

## 5. DECISIONS — present to the owner before implementing

**D1 — a terminal today, or the Buzz relay stack later? (answered in part)**
The client question is settled: the owner is considering **Buzz**, and the
intent is running it in a container, not pointing a client at a port (§3.5).
That splits D1 in two:

- **D1a — is a terminal enough *now*?** Option 1 costs nothing and is available
  today. It is only insufficient if the owner specifically wants a *graphical*
  agent client on the remote device. If "a terminal is fine", the LAN half of
  this item closes with a paragraph in `docs/extending-a-profile.md` and no
  code.
- **D1b — is Buzz worth the stack?** It is a much larger commitment than this
  item was scoped for: a relay service with Postgres + Redis + MinIO and a
  published port, a hosted-or-self-hosted decision, allowlist entries, a Rust
  binary with no open door into the image, and — the part to weigh hardest —
  an agent running with **none** of this repo's tool-level guardrails (§3.5).
  Its upside is genuine and specific: it is the only option here that gives
  remote access **without publishing anything from a profile container**, plus
  per-agent identity and a signed audit trail. **Ask:** is Buzz wanted as a
  workspace in its own right, or only as a remote-control transport? If the
  latter, option 1 or 2 does the same job for a fraction of the surface.

**D2 — LAN or mesh?**
If any remote access is enabled: raw LAN (option 1) or Tailscale/WireGuard
(option 2)? The second is strictly better on exposure and works away from home;
it adds a host-side daemon the sandbox does not audit. Owner's call — it is
their network.

## 6. Non-goals

- Publishing any port from a profile container without D1+D2 resolved and an
  ADR written.
- A bespoke Dockerfile or `docker run` path outside `scripts/profile.sh`.
- Any change to how credentials are supplied. `secrets.env` stays the route —
  including a Buzz agent's `BUZZ_PRIVATE_KEY`, which is an identity, not a
  config value.
- Running a Buzz agent inside a profile before a policy template and a hook
  dialect exist for whichever child it spawns. "It works" is not the bar here;
  §3.5 says plainly that it would work with nothing above the container
  boundary holding it.
- Running upstream's `sprig` image, or any second image, as a profile. Whatever
  enters, enters this repo's one shared image through a door that checks it.
