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
  - **PROJECT-PERSISTENT** — dev/ML stack (PyPI, npm, PyTorch, NVIDIA...).
    **Commented by default.** This tier used to be open in this repo; `fc7c0f0`
    closed pypi, npm, numerai and kaggle, and the audit probe
    (`gated_blocks_default_off`) now expects every gated tag here to be OFF.
  - **PLANNING-MODE** — commented by default; gated installs.
  - One documented exception: **`[git]`** is open in the committed baseline.
    `git push` and `uv pip install git+https://github.com/...` are the same
    host on the same port, so `dstdomain` cannot separate them — the block is
    open or the profiles cannot reach GitHub at all. The install half is held
    by `permissions.deny` and the `deny-destructive.sh` manifest rule instead.
    Full reasoning sits above the block in `proxy/allowed_domains.txt`; the
    probe defers to it via `ACCEPTED_OPEN_TAGS`. Widen that set only with a
    matching note in the allowlist.

## Temporary widening (preferred over hand-edits)

```bash
scripts/with-egress.sh <profile> --with playwright-install -- \
  'cd /workspace/foo && playwright install chromium'

scripts/with-egress.sh <profile> --with pypi,npm -- \
  'cd /workspace/foo && npm install && uv pip install -e ".[dev]"'
```

Uncomments the matching `[tag]` blocks, hot-reloads Squid, runs the command,
restores the allowlist **verbatim**. flock-serialised with a drift sentinel.
Default `--with` is `pypi`. `open_section()` is idempotent, so `--with git` on
the already-open `[git]` block adds nothing — every other gated tag is closed
and genuinely opens for the duration of the command.

## Permanent additions

1. Add the pinned host under the right tier with a `# --- name [tag] ---` header.
2. **Reload the proxy** — see below; restart and `squid -k reconfigure` both
   apply since the directory mount landed. Easiest is the dashboard's
   **"Save & Reload Proxies"** button (`just dashboard`), which edits the file
   and restarts every running proxy in one action. By hand:
   `docker restart egress-proxy-<profile>`.
3. Verify: from inside the agent, the new host resolves through the proxy and
   `https://example.com` is still blocked (`scripts/profile.sh <p> verify`).

## Applying an edit — restart or reconfigure, both work

Either applies the edit:

```bash
docker restart egress-proxy-<profile>
docker exec egress-proxy-<profile> squid -k reconfigure
```

**This changed on 2026-08-03 (16ae1b1).** Until then this section said
`reconfigure` exits 0 while applying nothing, and that was accurate — but the
cause was the *mount*, not the command. `proxy/allowed_domains.txt` was
bind-mounted as a single FILE, which pins an inode at container start, so any
atomic replace on the host (vim, `sed -i`, every `git checkout`/`merge`/`pull`)
left the container reading a deleted copy it could never escape. `reconfigure`
dutifully re-read the stale inode and returned 0.

`docker-compose.yml` now mounts the whole `./proxy` DIRECTORY, so the path
resolves on every read and the container always sees current bytes. The
silent-no-op mode is gone. `scripts/profile.sh <profile> verify` fails loudly
if the mount ever regresses to a file.

What has NOT changed: squid parses the allowlist into memory at start, so an
edit is not *enforced* until one of the two commands above runs. Grepping
`allowed_domains.txt` inside the container tells you what the file says, not
what squid enforces. `verify` now asks squid directly (de20901) instead of
inferring from mtime, so it catches file↔proxy drift; short of that, only an
egress probe settles it.

> A separate, older claim — that `reconfigure` *killed* the proxy (SIGHUP →
> exit 129) — is refuted. Squid is a child of `entrypoint.sh` (PID 1), handles
> SIGHUP as a reconfigure, and the container survives.

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
