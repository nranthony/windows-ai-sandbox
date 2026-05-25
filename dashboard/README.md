# Sandbox Control Dashboard

Host-side ops console for the windows-ai-sandbox stack. Runs on WSL2 Ubuntu,
talks to the rootless Docker daemon and the repo's config files. Not for use
inside any sandbox container.

## Setup

Requires [uv](https://github.com/astral-sh/uv).

```bash
cd dashboard
uv sync
```

## Run

```bash
cd dashboard
uv run streamlit run src/app.py
```

Bind address is pinned to `127.0.0.1` via `.streamlit/config.toml` — open
<http://127.0.0.1:8501> in your browser.

## Features

- **Status overview** — Docker daemon, profiles on disk vs running, egress
  proxy health per profile.
- **Proxy allowlist editor** — toggle blocks/domains in
  `proxy/allowed_domains.txt`, save, and reload `egress-proxy` for every
  running profile in one click. Detects stale bind mounts and offers
  one-click container recreate.

Everything else (lifecycle, logs, verify) stays on the CLI via
`scripts/profile.sh`.
