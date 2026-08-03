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

**An edit does nothing until a reload. Either reload mechanism works.**

1. **Dashboard → "Save & Reload Proxies"** (`just dashboard`) — writes the file and restarts
   every running proxy, then asserts a non-zero domain count. The supported path.
2. `docker restart egress-proxy-<p>` — same effect, one profile, no UI.
3. `docker exec egress-proxy-<p> squid -k reconfigure` — zero-downtime, and trustworthy
   again as of 2026-08-03. See below; this line has flipped twice, so read the reasoning
   rather than taking the instruction.

Squid parses the allowlist into memory at start, so a container-side `grep` shows the
*file*, not what is being *enforced*. Only a reload (or a probe) settles that. This is the
benign staleness mode — it self-resolves on any reload — and `verify` now settles it
decisively rather than guessing; see the next section.

### Enforcement probe (what `verify` actually asks)

`scripts/profile.sh <p> verify` asks squid directly. From **inside** the proxy container it
opens `/dev/tcp/127.0.0.1/3128` and sends `CONNECT <domain>:443` for every domain the repo
has **commented out**, then reads the status line:

| Response | Meaning | Verdict |
|---|---|---|
| `403` | the in-memory ACL denies it | expected — one summary line |
| `200` | squid **tunnels** a host the repo revoked | **FAIL** — stale enforcement |
| other (`503`, …) | ACL passed it, something later failed | WARN |
| no answer | probe could not run; nothing verified | WARN, never FAIL |

Two properties make this affordable in tier 1. A **403 comes from parsed config before any
DNS lookup or upstream connect**, so sweeping ~45 denied domains costs no egress and works
with the internet down. And it needs no section→host mapping — the file itself states which
domains are meant to be denied. (`bash` and `/dev/tcp` are both present in the pinned
`ubuntu/squid` image; no `squidclient`, `curl` or `nc` is, and the cache manager is
unreachable because port 3128 is not in `Safe_ports`.)

Building that denied set is the one place this can cry wolf, so three shapes are excluded
and locked by `scripts/with-egress.test.sh`: double-commented `# # --- Name [tag] ---`
section headers, prose comments, and — the live one — a domain commented under one tag while
**active** under another (`github.com` is commented under `[quarto-install]` and live under
`[git]`). Commented hosts covered by an *active* `.wildcard` parent are dropped too.

One allowed **canary** (`api.anthropic.com`) is probed and expected not to 403. That costs
one real connection and catches what the deny sweep cannot: squid enforcing some other
allowlist, or an empty one.

A `200` in the deny direction means squid completed a connection to a revoked host in order
to answer — unavoidable, and it *is* the evidence. It is also why the probe skips itself
while a `with-egress.sh` window is open (sentinel
`~/.ai-sandbox/profiles/.egress-widened-<p>`): it must never write into an audit bracket.

**Why not a timestamp.** `verify` used to warn when the allowlist's mtime was newer than the
proxy's `StartedAt`. That was wrong in both directions: under the directory mount every git
operation touching the file bumps mtime, so it fired on benign checkouts until it became
furniture; and `StartedAt` does not move on `squid -k reconfigure`, so it stayed silent after
a real edit that *had* been applied. Deleted, not demoted. The manual equivalent is still
useful when debugging — `docker exec -u proxy egress-proxy-<p> grep -E 'Starting Squid
Cache|Reconfiguring Squid Cache' /var/log/squid/cache.log | tail -1` gives the last parse
time (tmpfs, so current container only).

### The mount is what made reconfigure unreliable — fixed 2026-08-03

For most of this repo's life `proxy/allowed_domains.txt` was bind-mounted as a **single
file**. A file bind mount resolves to an inode once, at container start. So any host-side
operation that *replaces* the file rather than truncating it in place left the container
pinned to the old, deleted inode — unable to see host edits at all, with
`squid -k reconfigure` faithfully re-reading the stale copy and exiting 0.

| Edit style | Container saw new bytes? | `reconfigure` | `restart` |
|---|---|---|---|
| In-place (dashboard save, `>` truncate) | yes | ✅ applied | ✅ applied |
| **Atomic replace** (`vim`, `sed -i`, **every git checkout/merge/pull/stash**) | **no** | ❌ **silent no-op** | ✅ applied |

Measured twice, a week apart, in production: an atomic-replace edit commenting out
`arxiv.org` left it tunnelling `200` with the container on inode 275839 against a host file
of 275707; and on 2026-08-03 a **comment-only merge** left two of three proxies on inode
275834 against 81188, which `verify` reported as "in sync" (its content diff strips
comments) while `with-egress.sh` — the only install route — failed with
`tunnel error: unsuccessful`, naming nothing.

**The real cost was not the confusion. It was that the repo's allowlist became advisory:
tightening it in git did not take effect on a running proxy.** That is the G9 finding, where
all three proxies kept tunnelling a domain the repo had already gated.

**The fix: `docker-compose.yml` now mounts `./proxy` as a DIRECTORY** (`:/etc/squid/host:ro`).
Directory mounts resolve the path on every `open()`, so the container always sees current
bytes and the entire class disappears. Verified end-to-end: a `sed -i` moved the host inode
81188 → 368375, the container saw the change **with no restart**, and `squid -k reconfigure`
took a probe of `pypi.org` from `000` (denied) to `200` (allowed). The same sequence under
the file mount changed nothing at all.

Consequences worth knowing:

- `squid -k reconfigure` is sound again, and for the first time its exit code means
  something — there is no longer a mode where it reports success having applied nothing.
- `verify`'s inode comparison is now a **regression lock** rather than a live tripwire. It
  should never fire; if it does, someone reverted the mount to a file.
- `with-egress.sh`'s visibility check stopped being load-bearing for staleness. It is kept
  for a botched mount target and for profiles that predate the change.
- `squid.conf` stays a file mount deliberately: it needs a restart to be parsed anyway, and
  it was touched by 0 of the last 49 commits against the allowlist's 10. Same mount style,
  opposite edit profiles — which is why only one of them ever caused trouble.
- Mount at a **sub-path**. Never overmount `/etc/squid` wholesale; the image keeps
  `errorpage.css` and `conf.d/` there.

**Two earlier corrections, kept so they are not re-derived:** this file once called
reconfigure "preferred (zero-downtime)", then reversed to "never use it" — the truth was
that the command was always fine and the mount was broken. And it once appeared that
reconfigure *killed* the proxy (SIGHUP → exit 129); that is refuted, squid runs as a child
of `entrypoint.sh` (PID 1), handles SIGHUP as a reconfigure, and the container survives.

### Why it took two incidents to see it

The mechanism was documented after the first incident and the class still recurred, which is
the part worth remembering.

The 2026-07-31 write-up listed `git checkout` in a row alongside `vim` and `sed -i`, framed
as *editor* behaviour — a thing you do deliberately to the allowlist. That framing hid the
real exposure: **every branch switch, merge, pull, rebase or stash that touches the file
replaces the inode**, and that is the normal development loop of this repo, firing when
nobody has gone near an allowlist. Ten of the last 49 commits touched it, three proxies run
concurrently, and `restart: "no"` means they live for days — so one merge blinded all three
at once.

Diagnosis was slow because every signal pointed away from the cause:

1. `verify` said **"allowlist in sync"** — the comment-only merge left the stripped domain
   lists identical.
2. `with-egress.sh --with pypi` looked healthy: section opened, `reconfigure` returned 0,
   audit record written.
3. The install died with `tunnel error: unsuccessful`, which names nothing and points at
   the network.

The lesson is not "remember to restart after git operations". It is that a mitigation
requiring a human to remember an invisible coupling is not a mitigation. The general rule
underneath: **a bind-mounted file is a snapshot; a bind-mounted directory is a view.**
Taking that (above) removed the class instead of documenting it better.
