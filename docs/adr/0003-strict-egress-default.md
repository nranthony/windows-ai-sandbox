# ADR-0003: Package registries are unreachable by default; installs open a bounded window

- Status: Accepted
- Date: 2026-08-02
- Deciders: nranthony + agent
- Implements: [`docs/_archive/dependency-guardrails-plan.md`](../_archive/dependency-guardrails-plan.md) §13 D1
- Related: [ADR-0002](0002-dependency-guardrail-scope.md) (what we deliberately do not build)

## Context

The imported design documents assumed a `dev` posture: registries reachable, controls
layered on top. The application plan carried that recommendation forward as decision D1 —
`locked` vs `dev` as the default egress stance — and left it open.

Two things settled it.

**It was already the deployed reality.** Commit `fc7c0f0` had commented out pypi, npm,
numerai, kaggle and the VS Code marketplace tags. The proposed `dev` default was not a
choice about where to go; it was a proposal to *loosen* what had been running for weeks
without friction anyone had reported.

**The operator asked for it explicitly.** The stated preference was strict by default,
opened only for a given setup stage and closed again — motivated by having drifted out of
the habit of toggling the allowlist, partly because the dashboard's reload path was
unreliable (fixed separately; see the allowlist header).

The security argument is the one that makes the other two more than preference. **A
slopsquat payload cannot execute if no registry is reachable.** Every other control in the
guardrail effort — the deny list, the manifest hook, the age gate, the OSV cross-check —
reduces the probability that a bad package is *selected*. Only unreachability makes the
selection irrelevant. It is the sole control in the set that is categorical rather than
probabilistic, and it costs nothing when nobody is installing, which is almost all the time.

## Decision

**Registries and install-time hosts stay commented out in
[`proxy/allowed_domains.txt`](../../proxy/allowed_domains.txt). This is the steady state,
not a lockdown.** Reaching one is a deliberate, bounded act:

```bash
scripts/with-egress.sh <profile> --with npm -- 'cd /workspace/x && npm ci'
```

That opens the tag, runs exactly one command, restores the file verbatim, and is
flock-serialised and sentinel-tracked. Hand-editing the allowlist is permitted but
discouraged for the reason that motivated this ADR: **a hand edit has no automatic close**,
so a widened allowlist outlives the task that needed it. That is the failure mode being
designed out, and it is a human-factors failure, not a technical one.

Three supporting commitments:

1. The allowlist header states the deployed posture. It previously claimed registries were
   uncommented by default; they had not been since `fc7c0f0`. A file that misdescribes
   itself trains people to distrust it.
2. `scripts/profile.sh <profile> verify` fails if a running proxy's allowlist differs from
   the repo file, and warns if the file is newer than the proxy's start time. Strict-by-
   default is worth nothing if a proxy is quietly enforcing an older, wider set.
3. Editing the allowlist requires `docker restart egress-proxy-<profile>` — **not**
   `squid -k reconfigure`, which parses at startup and silently no-ops here.

## Consequences

- **`with-egress.sh` is the only install route.** That is what makes phase 3's
  instrumentation possible at all: there is exactly one place where dependencies can enter,
  so bracketing it captures every install. A `dev` default would have left no such
  chokepoint, and the audit log would have been a sample rather than a record.
- Anything that resolves dependencies on the fly breaks outside a window — `uv run`
  against an incomplete environment, a `pnpm run build` that installs, `container_testing`'s
  uv project. This was already true before the decision; the decision declines to fix it by
  loosening.
- The friction is real and is the point. It is also bounded: one command per install step,
  not per package.
- **This is not the security boundary.** The boundary remains rootless Docker + `cap_drop`
  + seccomp + `internal: true` + the allowlist itself. This ADR governs the *contents* of
  the allowlist, one layer of defence in depth.

## Alternatives considered

- **`dev` default (registries open), controls layered on top.** What the imported plans
  assumed. Rejected: it discards the only categorical control in the set to buy convenience
  during the small fraction of time spent installing.
- **Open registries per profile rather than globally.** Plausible and not refused
  permanently — but the allowlist is one file shared by all proxies, so this needs a
  per-profile allowlist mechanism that does not exist. Re-open if profiles diverge enough
  that one needs sustained registry access.
- **Keep strict, drop `with-egress.sh` in favour of hand edits.** Rejected for the reason
  in the Decision: no automatic close.
