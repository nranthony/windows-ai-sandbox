# Squid egress proxy — internals

User-facing allowlist edits: see `proxy/allowed_domains.txt` and `README.md`. This page covers the why behind the config.

## Caps

Squid starts as root then drops to the `proxy` user — needs `SETUID` / `SETGID`. Without them: crash-loop exit 134. `NET_BIND_SERVICE` is NOT needed (port 3128 is unprivileged). Also `pinger_enable off` in `squid.conf` — ICMP pinger wants `CAP_NET_RAW` we don't grant.

## Split-phase tmpfs ownership

Root opens `/run/squid.pid` and `cache.log`; proxy user uid 13 writes `access.log` and the cache disk.

| tmpfs | owner/mode | why |
|---|---|---|
| `/var/spool/squid` | `proxy:proxy 0750` | Written only post-drop. |
| `/var/log/squid` | `root:proxy 0775` | `cache.log` opened by root, `access.log` by proxy — both need to write. |
| `/run` | default (root:root) | `/run/squid.pid` created by root. Don't add `uid=13` here or PID write fails. |

Changes only re-apply on `--force-recreate` (not restart).

## Port-restrict non-CONNECT methods

`acl Safe_ports port 80 443` + `http_access deny !Safe_ports`. Without that, `http_access allow allowed_domains` forwards GET/POST to **any** port on allowed hosts.

## CONNECT restricted to port 443

The `deny CONNECT !SSL_ports` line is load-bearing. Without it, the `allow allowed_domains` rule would match `CONNECT api.anthropic.com:80` and tunnel raw TCP on cleartext port 80. `verify-sandbox.sh` includes a probe for this; a regression trips it.

## Avoid wildcards under vendor parents you don't control

Default allowlist uses specific subdomains (`api.anthropic.com`, `console.anthropic.com`, etc.) rather than `.anthropic.com` / `.claude.ai`. Wildcards are an exfil channel any time a vendor adds a user-controllable subdomain. When a new subdomain 403s, tail the access log to find it.

`.vscode-unpkg.net` stays a wildcard because VS Code's extension fetcher legitimately rotates across many subdomains under that single MS-controlled parent.

## Access log

Tmpfs-backed `proxy:proxy 0640` — forensic trail of every request, resets on `--force-recreate`. Read with: `docker exec -u proxy egress-proxy-<p> tail -f /var/log/squid/access.log`.

## Applying an allowlist edit

**Use a restart. `squid -k reconfigure` silently no-ops on the most common kind of edit.**

Preferred, in order:

1. **Dashboard → "Save & Reload Proxies"** (`just dashboard`) — writes the file and restarts
   every running proxy, then asserts a non-zero domain count. The supported path.
2. `docker restart egress-proxy-<p>` — same effect, one profile, no UI.
3. `scripts/profile.sh <p> up` after `docker rm -f egress-proxy-<p>` — for a wedged proxy.

### Why not `squid -k reconfigure` (measured 2026-07-31)

There are **two independent staleness modes**, and reconfigure only fixes one:

| Edit style | Container sees new bytes? | `squid -k reconfigure` | `docker restart` |
|---|---|---|---|
| **In-place** (dashboard save, `>` truncate) | yes — inode preserved | ✅ applies | ✅ applies |
| **Atomic replace** (`vim`, `sed -i`, `git checkout`, most editors) | **no — inode swapped** | ❌ **silently no-ops** | ✅ applies |

The trap is that **reconfigure exits 0 and logs "Processing Configuration File" in both
cases.** Measured: after an atomic-replace edit commenting out `arxiv.org`, reconfigure
returned 0 and `arxiv.org` still tunnelled (`200`). The container was pinned to inode
275839 while the host file had become 275707. A restart re-runs the entrypoint and
re-resolves the bind mount, so it is correct for both modes.

Note also that squid parses the allowlist into memory at start. Even with a live inode, an
edit is not enforced until a reconfigure or restart — so a container-side `grep` of
`allowed_domains.txt` shows the *file*, not what is being *enforced*. Only an egress probe
(or a reload) settles it.

**Correction:** this file previously called reconfigure "preferred (zero-downtime)". It is
not preferred. It also previously appeared that reconfigure *killed* the proxy (SIGHUP →
exit 129); that is refuted — squid runs as a child of `entrypoint.sh` (PID 1), handles
SIGHUP as a reconfigure, and the container survives. The real defect is the silent no-op
above, not a crash.
