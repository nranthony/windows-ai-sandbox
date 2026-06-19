# therapod pipeline — Postgres + DB + API setup

Stand up the [`therapod/pipeline`](../../../therapod/pipeline) ECG biofeedback
pipeline inside the `therapod` sandbox profile: a sibling Postgres on
`sandbox-internal`, the `pipeline` control-plane DB, an H10 backfill, and the
FastAPI app reachable inside the agent container.

The pipeline repo's own `CLAUDE.md` is written for the **macolima** (macOS)
sandbox. This doc maps that onto the **windows-ai-sandbox** opt-in Postgres
sibling — the same threat model, different substrate.

## Key facts (therapod)

| Thing | Value |
|---|---|
| Subnet octet | `187` → `sandbox-internal` = `172.30.187.0/24` |
| Postgres host/IP (in-sandbox) | `postgres:5432` → `172.30.187.20` (already in the agent's `extra_hosts`) |
| Named volume | `ai-sandbox-therapod_postgres-data` |
| Role / DB | user `agent`, database `pipeline` |
| Pipeline repo (in-container) | `/workspace/pipeline` (`/workspace` = `~/repo/therapod`) |
| H10 fixture (in-container) | `/workspace/raw_data/wearable_data/polar-h10/GalaxyPPG/polar_h10_ecg_parquet/P01..P24_ECG.parquet` |
| Venv | `/workspace/pipeline/.venv-linux` (on the bind mount; survives recreates) |
| API | `uvicorn` on `0.0.0.0:8001` **inside** the agent container |

Notes:
- **DB traffic is raw TCP**, so the Squid `HTTP_PROXY` does not touch it —
  `agent → postgres:5432` goes direct over `sandbox-internal`. No `NO_PROXY`
  change needed.
- The H10 fixture resolves automatically: `pipeline.bridge.mock._workspace_root()`
  walks up from `mock.py` to the first ancestor containing `raw_data/`, which is
  `/workspace`. No copy or symlink required.
- `pipeline`'s own `docker-compose.yml` (host-mode Postgres on `127.0.0.1:15432`)
  is **not** used here — that's the macOS-host path.

## Status — COMPLETE (2026-06-19)

- [x] **Step 1** — `db.env` created at `~/.ai-sandbox/profiles/therapod/db.env`
  (mode `600`, random `openssl rand -hex 24` password).
- [x] **Step 2** — `postgres-therapod` up; agent force-recreated, DSNs in env.
- [x] **Step 3** — `pipeline` database created (owner `agent`).
- [x] **Step 4** — `.venv-linux` + `pip install -e ".[dev]"` done.
- [x] **Step 5** — migrated to `009`; backfilled **24/24** participants;
  verifier **OVERALL PASS** (smoke + plausibility + throughput, 0 drops).
- [x] **Step 6** — API live on `:8001` (`/admin/ready` → `db_ok:true`).
- [x] **PG tune** — `synchronous_commit=off` (see below) — needed to get
  `live_state_dropped` to 0 at ~290× realtime backfill.

Control-plane after backfill: `sessions=24`, `gold_manifests=48`,
`event_log=48`, `live_session_state=48`.

## Step 1 — `db.env` (done)

`~/.ai-sandbox/profiles/therapod/db.env`, loaded as `env_file` into **both**
`postgres-therapod` (reads `POSTGRES_*`) and `ai-sandbox-therapod` (reads the
DSNs). Shape (password redacted):

```ini
POSTGRES_USER=agent
POSTGRES_PASSWORD=<48 hex>
PIPELINE_PG_DSN=postgresql://agent:<pw>@postgres:5432/pipeline
DATABASE_URL=postgresql+asyncpg://agent:<pw>@postgres:5432/pipeline
WEARDATA_PG_DSN=postgresql://agent:<pw>@postgres:5432/postgres
```

> `POSTGRES_USER`/`POSTGRES_PASSWORD` lock in on the **first** Postgres boot
> only (initdb against the empty volume). To change later: `ALTER USER agent
> WITH PASSWORD …`, or wipe `ai-sandbox-therapod_postgres-data` and re-up.

## Step 2 — Postgres up + DSNs into the agent  ⚠️ disruptive

```bash
COMPOSE_PROFILES=db-postgres scripts/profile.sh therapod up
```

Starts `postgres-therapod` **and force-recreates `ai-sandbox-therapod`** so it
re-reads `db.env` (the only way the DSNs land in every future `attach`). The
recreate drops in-container processes; bind-mounted state (auth, config,
`/workspace`) is preserved.

`COMPOSE_PROFILES=db-postgres` must be passed on **every** `up` (see "Make it
permanent" for removing this footgun).

## Step 3 — create the `pipeline` DB (once)

```bash
docker exec postgres-therapod psql -U agent -d postgres \
  -c 'CREATE DATABASE pipeline OWNER agent;'
```

## Step 4 — venv + deps (one-time pypi egress)

Pure-PyPI deps (no torch). Open `[pypi]` transiently for the install:

```bash
scripts/with-egress.sh therapod --with pypi -- '
  cd /workspace/pipeline &&
  uv venv .venv-linux --python 3.12 &&
  uv pip install -e ".[dev]" --python .venv-linux/bin/python'
```

## Step 5 — migrate, backfill, verify

Inside the agent (DSNs are in env after Step 2):

```bash
cd /workspace/pipeline
.venv-linux/bin/alembic upgrade head
.venv-linux/bin/python scripts/backfill_h10.py --participants 1-2   # smoke first
.venv-linux/bin/python scripts/backfill_h10.py --participants 1-24 --reset
.venv-linux/bin/python scripts/verify_pipeline_run.py
```

Output → `/workspace/pipeline/data/dev/`. Full 1-24 ≈ ~10 min. `--reset`
drops/recreates `pipeline`, re-runs alembic, and clears the data dir.

## Step 6 — API server (inside the agent)

```bash
cd /workspace/pipeline
PIPELINE_DATA_DIR=data/dev nohup .venv-linux/bin/uvicorn \
  pipeline.api:create_app --factory --host 0.0.0.0 --port 8001 --workers 1 \
  > /workspace/pipeline/uvicorn.log 2>&1 &
```

Reachable at `http://localhost:8001` from inside the container
(`/docs`, `/admin/ready`). Port `8001` is in the profile's forwarded set.
Use `--workers 1` — the in-memory active-pipelines registry is single-process.

## Postgres tuning — `synchronous_commit=off`

At ~290× realtime, the Gold scheduler's 1 Hz sliding UPSERTs to
`live_session_state` outrun Postgres's fsync-per-commit on the WSL2 named
volume, so the bounded writer queue (`drop_oldest_on_full`) sheds rows and the
verifier's THROUGHPUT check fails on `live_state_dropped > 0`. `live_session_state`
is an overwrite "latest value" table (not durable truth), so the drops are
cosmetic for backfill — but to get a clean PASS:

```bash
docker exec postgres-therapod psql -U agent -d postgres \
  -c "ALTER SYSTEM SET synchronous_commit = off;" -c "SELECT pg_reload_conf();"
```

Cluster-wide (survives `backfill --reset`'s `DROP DATABASE`, and persists in
`postgresql.auto.conf` on the named volume across restarts). Took drops 4940 → 0.
Durability trade-off: a crash could lose the last fraction of a second of
committed transactions — fine for a dev control plane.

## Restarting after a container/host restart

- **Postgres + agent**: `restart: "no"`, so after a host reboot bring the stack
  back with `COMPOSE_PROFILES=db-postgres scripts/profile.sh therapod up`. DB
  data (named volume), `.venv-linux` + Parquet (bind mount), and the PG tune all
  persist.
- **API server** is a detached `uvicorn` inside the agent, so it dies on any
  container restart/recreate. Bring it back with one command —
  **`scripts/profile.sh therapod api up`** (or `just api therapod up`),
  idempotent and health-checked. `api down|status|logs` round it out. (It does
  not auto-start on `up`; see "Make it permanent" for the zero-touch
  compose-service option.)

## Make it permanent (optional repo changes)

1. **Default `db-postgres` on for therapod.** Add a per-profile
   `compose-profiles` file (mirroring `subnet-octet`) and have `profile.sh`
   default `COMPOSE_PROFILES` from it, so the DB sibling comes up on every `up`
   without the env-var prefix.
2. **API as a managed process** instead of a backgrounded `nohup` — a small
   in-container supervisor or a compose overlay service on `sandbox-internal`,
   if auto-restart is wanted.

## See also

- `therapod/pipeline/CLAUDE.md` § "Where to find Postgres — by execution context"
- `therapod/pipeline/docs/dev_runbook.md` — backfill + verify + API inspection
- `config/db.env.template` — the credential template this `db.env` was based on
