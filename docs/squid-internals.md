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

## Hot reload

Preferred: `docker exec egress-proxy-<p> squid -k reconfigure` (zero-downtime). Fall back to `docker compose restart egress-proxy` only when the container is unhealthy.
