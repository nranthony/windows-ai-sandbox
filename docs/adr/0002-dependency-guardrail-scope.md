# ADR-0002: Dependency guardrails — what we deliberately do not build

- Status: Proposed
- Date: 2026-07-31
- Deciders: nranthony + agent
- Implements: [`work/0001-dependency-guardrails/plan.md`](../../work/0001-dependency-guardrails/plan.md) §3

## Context

Three imported design documents ([`docs/rfcs/`](../rfcs/)) propose a dependency-guardrail
system: a posture scanner (`depaudit`), a five-gate enforcement layer (`depgate`), and a
portable host-side subset. They were written for an organisation with a fleet of repos and
no containment.

This repo is the opposite shape: one developer, a handful of profiles, and an egress model
— `internal: true` + DNS sinkhole + Squid allowlist — that already delivers what plan 02
calls the hardest gate to obtain. Adopting the proposals as specified would add services
and vendors *inside* a security boundary built on minimalism, to defend against a threat
the boundary already contains.

The refusals below were argued out while writing the application plan. Recorded as an ADR
because each one will otherwise be re-proposed every time someone reads plan 02 and notices
we did not build it — and because several of them affect the security boundary, which is
the ADR threshold set in [ADR-0001](0001-provenance-tiers.md).

## Decision

Do not build the following. Each entry names the re-open condition where one exists.

**Verdaccio + devpi inside the egress container** (plan 02 §4). Two new Node/Python
services, *with their own dependency trees*, placed inside the security boundary, to guard
against dependency compromise. Plan 02 §4 concedes the bootstrapping problem and offers
only partial mitigations. It also contradicts `sandbox-hardening-package.md` §7's
minimalism, where bubblewrap/socat/openssh are deliberately absent. The value it uniquely
adds — a pip age gate and artifact inspection — is real; see re-open conditions.

**Gate 1 as an HTTP policy service.** The service exists in plan 02 to stop N call sites
drifting. We will have two, both in the same script. A shared function is the correct shape
at this scale.

**SARIF output** (plan 01 §8). No GitHub code-scanning ingestion in this repo's workflow.
Add if that changes.

**Fleet mode** (plan 01 §8). The "fleet" is `~/repo/<profile>/`. `depaudit posture` over a
glob is the whole feature.

**`policy.yaml` as a versioned artifact in its own repo** (plan 02 §2). Correct at org
scale, overhead here. Keep a single `depaudit/policy.toml` in-repo — TOML so `tomllib`
reads it, no YAML parser, per the stdlib-only rule. Revisit if macolima needs to share it.

**Socket Firewall (`sfw`)** — an install-time proxy for npm/yarn/pnpm/pip/uv/cargo. The
argument for it is real: *the exposure is the ~200 transitive dependencies, not the package
you chose.* But we answer that twice already — plan 01 §5's `inventory` resolves the full
tree including transitives from lockfiles, and `enrich` runs over every unique
`(ecosystem, name)`, not just direct deps; the application plan's phase 3 closes the
remaining timing gap by diffing the lockfile *inside* the install window. Adopting `sfw`
would place a third-party binary that proxies every install inside the security boundary,
requiring egress to a vendor service. It is the correct answer for a host with no window —
see [plan 04](../rfcs/04-portable-guardrails-outside-sandbox.md) §6 — and the wrong one
here.

**Socket `batchPackageFetch`** (behavioural analysis, ~1k scans/month free). Genuinely
catches what OSV cannot: compromises before an advisory exists. But it costs a new
allowlist entry, an API key in `secrets.env`, and a vendor in the trust path. Revisit once
OSV's hit rate is known from phase 3 telemetry. Do not add a second source before the first
has been observed.

**`osv-scanner` binary.** A Go binary to avoid writing a `urllib` POST. The stdlib-only
rule says no; the API is one stdlib call, verified working.

**Local OSV mirror** (`gs://osv-vulnerabilities`). Would make the check work in-container
and offline, and `storage.googleapis.com` is already allowlisted for Kaggle. But it is
~240k advisory records to sync and keep fresh, against a check that runs host-side where
the live API is free. Revisit only if the check moves in-container.

## Consequences

- The application plan builds four things instead of a system: behavioural rules, config
  gates, a read-only host-side scanner, and instrumentation of an install window that
  already exists.
- Nothing new runs inside the security boundary. The stdlib-only rule is preserved for
  `depaudit`, matching `sandbox_templates/bin/webfetch`.
- No vendor enters the trust path and no API key is added, so the threat-intel cross-check
  costs zero new egress surface — `api.osv.dev` is reached host-side, where egress is
  unrestricted.
- Each refusal is now citable. A future proposal to add one of these is an amendment to
  this ADR, not a fresh argument.

## Re-open conditions

Re-open the registry-proxy decision (Verdaccio/devpi) if **any** of these become true:

- pip/uv usage grows enough that the missing Python age gate is the dominant risk;
- a second person gets access to the sandbox;
- artifact-level inspection, rather than name-level, becomes a requirement.

Until then, the application plan's phase 2 — allowlist-gated registries plus per-tool age
gates — is the cheaper substitute covering most of it.

## Alternatives considered

- **Build `depgate` as specified.** Rejected: it is a design for an environment without
  containment. Here it would duplicate Gate 4 in software while adding attack surface.
- **Adopt nothing and rely on the egress boundary alone.** Rejected: the allowlist gates
  hosts, not package names. Once a window is open, any package on the registry is
  reachable — which is the gap the age gate exists to close.
- **Defer all of it until a second person joins.** Rejected: the controls that matter most
  (a human naming each dependency; a quarantine window) are cheapest to adopt before
  habits set, and the autonomous-agent case is exactly the one with no human in the loop.
