# 0023 — Implementation plan: Ollama sibling container

Ordered steps for [spec.md](spec.md). Branch `feat/0023-ollama-sibling`.
Security-sensitive files touched: `docker-compose.yml`, `docker-compose.wsl-gpu.yml`,
`scripts/profile.sh`, `scripts/init-profile-state.sh`, `scripts/verify-sandbox.sh`.

## Phase 0 — baseline
- `just test-offline` green on `main` before the first edit.
- Pin the image: `docker buildx imagetools inspect ollama/ollama:latest` →
  index digest `sha256:32931b46719f673c05fdbaa81ccb26da18ea4a1c57590a754874ab28ba269eb2`
  (2026-09-03). `docker pull` by that reference for Phase 4.

## Phase 1 — compose
1. `docker-compose.yml`
   - `ai-sandbox`: add `"ollama:172.30.${SANDBOX_OCTET:-0}.40"` to `extra_hosts`;
     add `ollama` to `NO_PROXY` and `no_proxy`.
   - New service `ollama` after `mongo`, comment block in the same voice as the
     DB siblings: pinned image + refresh recipe, `container_name: ollama-${PROFILE}`,
     `hostname: ollama`, `profiles: ["ollama"]`, `read_only: true`, tmpfs
     `/root/.ollama` and `/tmp`, volume `${HOME}/.ai-sandbox/models/ollama:/models:ro`,
     env `OLLAMA_HOST=0.0.0.0:11434`, `OLLAMA_MODELS=/models`, network pin `.40`,
     commented loopback `ports:`, `security_opt no-new-privileges`, `cap_drop: ALL`,
     `pids_limit: 512`, `mem_limit: 16g`, `cpus: 4`, `restart: "no"`.
   - Header comment: the `.40` pin joins the `.10/.20/.30` list.
2. `docker-compose.wsl-gpu.yml`: `ollama:` block with the same three lines as
   `ai-sandbox` (`/dev/dxg`, `/usr/lib/wsl:ro`, `LD_LIBRARY_PATH`).

## Phase 2 — host state
- `init-profile-state.sh` and `ensure_state`: `mkdir -p ~/.ai-sandbox/models/ollama`
  (shared, NOT under the profile dir — say so in the comment; D1/D4).

## Phase 3 — `profile.sh`
1. `compose-profiles` becomes a comma list. Add helpers near `ensure_compose_profiles`:
   `read_compose_profiles` (file → list), `write_compose_profiles`,
   `compose_profiles_has <token>`, `compose_profiles_set_db <db-*|"">`,
   `compose_profiles_toggle ollama on|off`. `ensure_compose_profiles` exports
   the joined list unchanged.
2. `db enable|disable` rewritten on those helpers — `disable` clears only the
   `db-*` token and deletes the file only when nothing is left; `status` prints
   the whole list.
3. New `ollama` subcommand: `enable | disable | status | pull <model> |
   create <name> -f <Modelfile> | list | rm <model>`. `pull`/`create`/`rm`/`list`
   run `docker run --rm` on the pinned image (read from `docker-compose.yml`
   with one grep so the pin is not duplicated), store mounted `rw` at
   `/root/.ollama`, default bridge, `--cap-drop ALL`, `--security-opt
   no-new-privileges`. `pull` appends `date model digest` to `pull.log`
   (digest via `ollama show --modelfile`'s FROM line or the manifest file —
   whichever the image exposes; measure). `enable` writes the token and prints
   the `up` hint, mirroring `db enable`.
4. `health`: `o_s=$(cstate "ollama-$p")`; expected iff the persisted list has
   `ollama`; orphan/leftover handling identical to the DB branches; the
   `sed -n -E` profile-discovery pattern gains `ollama`; the table's DB column
   becomes SIBLINGS.
5. Usage header: `ollama <SUB>` entry; `db` entry notes the list form.
6. `justfile`: `ollama profile *args` recipe.

## Phase 4 — verify + measure (live, `nranthony`)
1. `verify-sandbox.sh`, new group "agent backend / ollama sibling":
   - print `ANTHROPIC_BASE_URL` if set (INFO), WARN if set to anything other
     than `http://ollama:11434` or an allowlisted https host — a base URL the
     proxy will refuse is a silent "every request fails".
   - if `getent hosts ollama` resolves and `curl --noproxy '*' http://ollama:11434/api/version`
     answers → PASS with the version; if it does not answer → `note` N/A
     (sibling not enabled). Never FAIL on absence.
2. Bring up: `scripts/profile.sh nranthony ollama enable && … up`.
   Measure and record in `notes.md`:
   - air gap from inside `ollama-nranthony` (`/proc/net/route` has no default;
     no proxy vars) — the image has no curl, so read `/proc`.
   - `curl http://ollama:11434/api/version` from the agent, direct (not via Squid).
   - `getent hosts example.com` still fails in the agent.
   - GPU: `docker logs ollama-nranthony` for the CUDA/NVML discovery lines;
     `nvidia-smi` on the host while a model is loaded.
   - read-only store: `POST /api/delete` and `/api/create` from the agent must fail.
   - the count_tokens issue: `claude` with the three env vars against a small
     pulled model — does `/v1/messages/count_tokens` 404 wedge the server?
3. `just test-offline`, `profile.sh nranthony verify`, then `audit`.

## Phase 5 — docs
- `ARCHITECTURE.md`: sibling in the per-profile tree, `.40` in the network
  bullet, `~/.ai-sandbox/models/ollama/` in the state layout (shared, ro).
- `AGENTS.md`: quick-reference line; state-placement table row (models: host
  dir, shared, read-only to the runtime).
- `.agents/skills/profile-lifecycle.md`: "Local inference (Ollama sibling)"
  section next to Databases, including the Claude Code backend switch and
  its documented consequences; fix the stale "plain `up` does NOT start the DB
  siblings" note while there (it has been persisted since `db enable`).
- `sandbox_templates/common/secrets.env.template`: commented block for the
  three variables (Ollama form and OpenRouter form), with the caveats from
  spec §8 and the recreate-after-edit rule.
- `docs/index.md`: link the new lifecycle section under GPU & Docker.
- `work/README.md`: 0023 row → implemented; 0009 row → motivation narrowed.

## Commit shape
One commit per phase where it stands alone (compose; profile.sh; verify; docs),
each with a SECURITY IMPACT line. Nothing pushed.
