# Skill: Squid Egress Allowlist Management

`proxy/allowed_domains.txt` is the single choke point for agent egress —
treat every edit as a security change (AGENTS.md protocol applies).

## File conventions (violating these breaks Squid or the audit)

- One domain per line. Leading dot = all subdomains (`.github.com`).
- **NO inline comments** — `dstdomain` treats the whole line as a hostname.
  Notes go on their own `#` lines.
- **Pinned subdomains, no parent wildcards** for anything hosting
  user-controllable content (audit M3): `api.anthropic.com`, never
  `.anthropic.com`. A Squid 403 tells you which specific host to add.
- Blocks are tagged `[name]` for grep and for `with-egress.sh --with name`.
- Three lifecycle tiers, top to bottom:
  - **ALWAYS ON** — never comment out.
  - **PROJECT-PERSISTENT** — dev/ML stack (PyPI, npm, PyTorch, NVIDIA...),
    uncommented by default in this repo.
  - **PLANNING-MODE** — commented by default; gated installs.

## Temporary widening (preferred over hand-edits)

```bash
scripts/with-egress.sh <profile> --with playwright-install -- \
  'cd /workspace/foo && playwright install chromium'

scripts/with-egress.sh <profile> --with pypi,npm -- \
  'cd /workspace/foo && npm install && uv pip install -e ".[dev]"'
```

Uncomments the matching `[tag]` blocks, hot-reloads Squid, runs the command,
restores the allowlist **verbatim**. flock-serialised with a drift sentinel.
Default `--with` is `pypi`. Tags in PROJECT-PERSISTENT sections are accepted
but no-ops (already open).

## Permanent additions

1. Add the pinned host under the right tier with a `# --- name [tag] ---` header.
2. Hot-reload: `docker exec egress-proxy-<profile> squid -k reconfigure`
   (or `COMPOSE_PROJECT_NAME=ai-sandbox-<p> PROFILE=<p> docker compose restart egress-proxy`).
3. Verify: from inside the agent, the new host resolves through the proxy and
   `https://example.com` is still blocked (`scripts/profile.sh <p> verify`).

## Debugging denials

Squid access log (tmpfs, inside the proxy container):

```bash
docker exec egress-proxy-<profile> tail -f /var/log/squid/access.log
# TCP_DENIED/403 lines name the exact host to pin
```

Internals (cap model, tmpfs ownership, port restrictions):
`docs/squid-internals.md`.
