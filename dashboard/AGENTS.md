# Sandbox Control Dashboard

Host-side Streamlit ops console for the sandbox stack (status overview +
proxy-allowlist editor). Runs on the HOST (WSL2 Ubuntu or bare Linux), never
inside a sandbox container. Human-facing setup/run details: [README.md](README.md).

## Tech stack

- Python ≥ 3.12, managed by **uv** (`uv sync`, `uv run` — never bare pip)
- Streamlit UI (`src/app.py` + `src/pages/`), Python Docker SDK (`src/lib/docker_client.py`)

## Workflow

```bash
cd dashboard
uv sync
uv run streamlit run src/app.py     # http://127.0.0.1:8501
```

## Guidelines

- **Docker access**: rootless daemon socket `unix:///run/user/1000/docker.sock`
  only. Never require or assume a rootful daemon; never run as root.
- **Loopback only**: Streamlit binds `127.0.0.1` via `.streamlit/config.toml`.
  Do not change the bind address — this is an ops tool, not a service.
- **Allowlist edits**: write `proxy/allowed_domains.txt` relative to the repo
  root, preserving its conventions (no inline comments, pinned subdomains,
  `[tag]` block headers — see `.agents/skills/squid-management.md`), then
  reload each running profile's proxy
  (`docker exec egress-proxy-<profile> squid -k reconfigure`).
- **Scope**: read-mostly. Lifecycle operations (up/down/rebuild/verify) stay
  on the CLI via `scripts/profile.sh` — do not reimplement them here (root
  AGENTS.md golden rule 1).
