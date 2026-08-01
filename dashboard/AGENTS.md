# Sandbox Control Dashboard

Host-side Streamlit ops console for the sandbox stack (status overview +
proxy-allowlist editor). Runs on the HOST (WSL2 Ubuntu or bare Linux), never
inside a sandbox container. Human-facing setup/run details: [README.md](README.md).

## Tech stack

- Python ≥ 3.12, managed by **uv** (`uv sync`, `uv run` — never bare pip)
- Streamlit UI — single page, tabs in the main panel, no sidebar
  (`src/app.py` assembles `src/lib/status_view.py` +
  `src/lib/proxy_allowlist_view.py`); Python Docker SDK (`src/lib/docker_client.py`)

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
  reload each running profile's proxy with a **restart**, not a reconfigure
  (`docker restart egress-proxy-<profile>`). `squid -k reconfigure` **exits 0 and
  applies nothing** after an atomic-replace edit (vim, `sed -i`, `git checkout`):
  the swap gives the host file a new inode while the container stays bound to the
  old one, so the reload re-reads a file that no longer changes. Only a restart
  re-resolves the mount. Measured 2026-07-31; see `docs/squid-internals.md`.
  (An earlier note here claimed reconfigure *killed* the proxy via SIGHUP — that
  is refuted; squid is a child of `entrypoint.sh`, not PID 1. Restart is still
  correct, for the inode reason.)
- **The "Save & Reload Proxies" button is the supported allowlist path.** It
  writes the file and restarts every running proxy, asserting a non-zero domain
  count each. Its write truncates in place and never swaps the inode, so the
  dashboard is not a source of allowlist drift — hand/git edits that are never
  reloaded are. Verified end-to-end 2026-07-31 in both directions.
- **Scope**: read-mostly. Lifecycle operations (up/down/rebuild/verify) stay
  on the CLI via `scripts/profile.sh` — do not reimplement them here (root
  AGENTS.md golden rule 1).
