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
2. **Apply it with a restart, not a reconfigure** — see below. Easiest is the
   dashboard's **"Save & Reload Proxies"** button (`just dashboard`), which edits
   the file and restarts every running proxy in one action. By hand:
   `docker restart egress-proxy-<profile>`.
3. Verify: from inside the agent, the new host resolves through the proxy and
   `https://example.com` is still blocked (`scripts/profile.sh <p> verify`).

## Applying an edit — use restart, never `squid -k reconfigure`

**`squid -k reconfigure` exits 0 while silently doing nothing, for the most common
kind of edit.** Measured 2026-07-31:

| Edit style | Container sees new bytes? | `reconfigure` | `docker restart` |
|---|---|---|---|
| In-place (dashboard save, `>` truncate) | yes — inode preserved | ✅ applies | ✅ applies |
| Atomic replace (`vim`, `sed -i`, `git checkout`) | **no — inode swapped** | ❌ **silent no-op** | ✅ applies |

After an atomic-replace edit commenting out `arxiv.org`, `reconfigure` returned 0,
logged "Processing Configuration File", and `arxiv.org` still tunnelled (`200`).
Most editors and every git operation replace atomically, so this is the normal
case, not the edge case.

A second, separate point: squid parses the allowlist into memory at start. Even
with a live inode, an edit is not *enforced* until a reload — so grepping
`allowed_domains.txt` **inside** the container tells you what the file says, not
what squid is enforcing. Only an egress probe or a reload settles it.

> Earlier notes here and in the dashboard claimed `reconfigure` *killed* the proxy
> (SIGHUP → exit 129). That is refuted: squid is a child of `entrypoint.sh` (PID 1),
> handles SIGHUP as a reconfigure, and the container survives. The defect is the
> silent no-op, not a crash — but the fix is the same one, so `restart` stands.

## The dashboard is the supported path

`just dashboard` → **Proxy Allowlist** tab → **"Save & Reload Proxies"**.
It writes `proxy/allowed_domains.txt`, restarts every running proxy, and asserts a
non-zero domain count per profile, surfacing a **Recreate** button for any proxy
that does not come back. Verified end-to-end 2026-07-31 in both directions
(removing a domain then restoring it, confirmed by egress probe each way).

Its file write uses in-place truncation, so it never swaps the inode — the
dashboard has never been a *cause* of allowlist drift. Drift comes from editing the
file by hand or by git and not reloading afterwards.

## Recreating the proxy (network wedge)

A stale bind mount (external edit swapped the allowlist file's inode) needs a
full **recreate** or restart, not `squid -k reconfigure` — only a fresh container
re-binds the mount to the current inode. Always recreate via
`scripts/profile.sh <p> up` (force-remove first if it is already running:
`docker rm -f egress-proxy-<p> && scripts/profile.sh <p> up`).

Do **NOT** recreate the proxy with a raw, service-scoped
`docker compose up -d --force-recreate egress-proxy` from a shell that lacks
the profile env. Without `SANDBOX_OCTET`, compose computes the wrong expected
subnet (`172.30.0.x` vs the live `172.30.<octet>.0/24`), decides
`sandbox-internal` is stale, and tries to remove it — which fails because the
running sandbox pins an endpoint, leaving the proxy **half-attached**
(`sandbox-external` only). Every later recreate then errors with
`is not connected to the network` / `network has active endpoints`.

`profile.sh` is immune (it exports `SANDBOX_OCTET` via `ensure_octet_free`), so
both `up` and `recreate` are safe. Recovery from a wedged proxy:
`docker rm -f egress-proxy-<p> && scripts/profile.sh <p> up`. The dashboard's
`recreate_proxy` routes through `profile.sh` for exactly this reason.

## Debugging denials

Squid access log (tmpfs, inside the proxy container):

```bash
docker exec egress-proxy-<profile> tail -f /var/log/squid/access.log
# TCP_DENIED/403 lines name the exact host to pin
```

Internals (cap model, tmpfs ownership, port restrictions):
`docs/squid-internals.md`.
