# 0023 — execution notes

## 2026-09-03 — pre-implementation probes (throwaway containers, no profile touched)

Image `ollama/ollama:latest@sha256:32931b46…` = Ollama **0.33.3**, 5.4 GB. No
`curl` in the image; `/bin/sh` present; ENTRYPOINT is `ollama`.

**Store layout.** With the store bind-mounted at `/root/.ollama` Ollama nests
everything under `models/` and writes its `id_ed25519` keypair into the shared
store. With `OLLAMA_MODELS=/models` and the store at `/models`, the root holds
`manifests/` and `blobs/` directly and the keypair goes to `/root/.ollama`
(tmpfs). The latter is the layout used on both sides (runtime `:ro`, pull `:rw`).

**Host-side pull pattern works**: `--entrypoint /bin/sh … -c 'ollama serve
>/dev/null 2>&1 & sleep 2; ollama pull smollm2:135m'` under `--cap-drop ALL
--security-opt no-new-privileges --pids-limit 512` on the default bridge →
`success`, manifest at `manifests/registry.ollama.ai/library/smollm2/135m`.

**Runtime under the spec's hardening** (`--read-only`, tmpfs `/root/.ollama`
+ `/tmp`, `cap_drop ALL`, `no-new-privileges`, `--network none`, `/dev/dxg` +
`/usr/lib/wsl:ro` + `LD_LIBRARY_PATH=/usr/lib/wsl/lib`, store `:ro`):

- `Listening on [::]:11434 (version 0.33.3)`
- `inference compute … library=CUDA compute=8.6 name=CUDA0 description="NVIDIA
  GeForce RTX 3080 Ti" libdirs=ollama,cuda_v13 driver=13.3 total="12.0 GiB"`
  — the WSL driver userland is found through `LD_LIBRARY_PATH`, same as the
  agent container. Generation ran on the GPU (`CUDA0 KV buffer size`,
  `loaded runners count=1`), `nvidia-smi` shows the process.
- `OLLAMA_KEEP_ALIVE:5m0s` default confirmed (D5).
- **Phone-home attempts at start**: `GET https://ollama.com/api/tags` ("model
  show cloud cache hydration") and `/api/experimental/model-recommendations`,
  both `network is unreachable` — the air gap holds. `OLLAMA_NO_CLOUD=true`
  added to the service so this is explicit, not incidental.
- `ollama rm smollm2:135m` → `Error: remove /models/manifests/…: read-only
  file system` (D4 holds at the runtime, independent of the API layer).

## 2026-09-03 — Phase 4, live on `nranthony` (agent NOT recreated)

`ollama enable` + `up ollama` started `ollama-nranthony` beside the running
agent; the agent container itself predates the compose change and was left
alone (a VS Code server was attached). Agent-side checks therefore ran from a
throwaway `windows-ai-sandbox:latest` container on the profile's
`sandbox-internal` with the new `extra_hosts`/`NO_PROXY` values passed by hand.

| Check | Result |
|---|---|
| sibling `/proc/net/route` | one entry, `172.30.108.0/24`, **no default route** |
| sibling env | `OLLAMA_HOST`, `OLLAMA_MODELS=/models`, `OLLAMA_NO_CLOUD=true` — no proxy vars |
| sibling GPU | `inference compute … library=CUDA … RTX 3080 Ti … driver=13.3` via the overlay |
| `ollama pull qwen3:0.6b` (helper) | success; `pull.log` line with the manifest sha256 |
| agent → `http://ollama:11434/api/version` | `{"version":"0.33.3"}` direct (NO_PROXY) |
| agent `getent hosts example.com` | NXDOMAIN — sinkhole intact |
| agent `DELETE /api/delete` | `read-only file system` |
| agent `POST /api/create` (system-prompt plant) | `chtimes … read-only file system` |
| `POST /v1/messages/count_tokens` | **404**, server still answers afterwards — #13949 wedge not reproduced |
| `claude -p … --model sonnet` with `ANTHROPIC_DEFAULT_SONNET_MODEL=qwen3:0.6b` | exit 0; Squid never involved; server log shows four `POST /v1/messages 200` from the probe |

Claude Code prints an `unrecognized_model` notice for a non-Anthropic name and
assumes a 200k window; `CLAUDE_CODE_MAX_CONTEXT_TOKENS` sets the real one.
Recorded, not acted on — it is a quality knob, not a boundary.

**Two things the live agent taught, after the first verify run:**

1. `ollama` resolved inside the OLD agent (created before the compose edit,
   `ExtraHosts` = proxy/postgres/mongo only). `/etc/resolv.conf` there is
   `127.0.0.11`: Docker's embedded resolver answers same-network service names
   itself and forwards the rest to the sinkholed upstream. So `extra_hosts` is
   belt-and-braces for resolution, not the only path — the comment in
   `profile.sh` ("extra_hosts is the ONLY name resolution path") overstates it.
   Left as found; noted for whoever next touches the DNS section.
2. The stale-agent failure that DOES bite is `NO_PROXY`: the old agent sends
   `http://ollama:11434` through squid and gets **403**. `verify` now checks
   `NO_PROXY` contains `ollama` and fails with the recreate hint; the
   `--noproxy` reachability probe alone would have passed and hidden it.

**Owner step left**: `scripts/profile.sh nranthony recreate` to pick up the
agent's new `NO_PROXY`/`extra_hosts` (drops the VS Code attach), then `verify`.
Until then tier-1 `verify` FAILs on the NO_PROXY line for that agent — the
designed signal for exactly this state.
