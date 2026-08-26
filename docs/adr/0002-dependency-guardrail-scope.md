# ADR-0002: Dependency guardrails — what we deliberately do not build

- Status: **Accepted** 2026-08-02 (Proposed 2026-07-31)
- Date: 2026-07-31; accepted after phases 0–2 shipped
- Deciders: nranthony + agent
- Implements: [`docs/_archive/dependency-guardrails-plan.md`](../_archive/dependency-guardrails-plan.md) §3

**Accepted on evidence, not intent.** Phases 0–2 are complete and every refusal below held:
nothing on the list was adopted, and no gap appeared that one of them would have filled.
`depaudit` shipped stdlib-only and host-side, nothing new runs inside the security boundary,
and no vendor or API key entered the trust path.

One correction to the text below: the `policy.toml` it says to "keep" was never created.
No threshold needed to be configurable — the quarantine window is enforced by npm/pnpm
themselves and the rest are CLI flags with defaults. Create it when a second consumer needs
to disagree about a threshold, not before.

## Context

Three imported design documents ([`docs/rfcs/`, closed 2026-08-25, kept in `docs/_archive/`](../_archive/)) propose a dependency-guardrail
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
see [plan 04](../_archive/04-portable-guardrails-outside-sandbox.md) §6 — and the wrong one
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

## Addendum 2026-08-24 — the price of a vulnerability scan went to zero; the noise argument did not

This ADR says explicitly that "a future proposal to add one of these is an amendment to this
ADR, not a fresh argument". This is that amendment. Nothing above is reversed; two refusals
are re-priced and one re-open condition is recorded as partly fired. Mechanically it is a
dated addendum rather than a superseding ADR, following
[ADR-0004](0004-python-wheels-only.md)'s precedent — the decision still stands, the world
around two of its cost arguments changed.

**What changed.** Both the `osv-scanner` refusal ("a Go binary to avoid writing a `urllib`
POST") and the local-mirror refusal ("~240k advisory records to sync and keep fresh") were
arguments about **cost**, not about value. Measured 2026-08-24: `uv audit` exists in uv
0.12.5, reads `uv.lock` directly, and carries `--frozen`, `--output-format json`,
`--service-format osv`, `--service-url`, `--ignore` and `--ignore-until-fixed`. uv is
already on the host and already baked into the image. No new binary, no vendored corpus, no
API key, no vendor in the trust path — the exact costs both refusals were made of. It caches
what it fetches under `~/.cache/uv/osv-v0/`. It still prints an "experimental" banner, which
is a reason to keep it non-gating, not a reason to skip it.

**What did NOT change, and must not.** `depaudit` reports `MAL-` records only, because
`GHSA-`/`PYSEC-`/`CVE-` answer a different question, and *mixing them is how a supply-chain
gate becomes a CVE treadmill nobody reads.* That reasoning is untouched by cost. So the
wiring is walled off from it (`scripts/profile.sh <p> deps --vulns`):

- opt-in, so a bare `deps` stays offline and tier-1 `verify` stays offline by contract;
- printed under its own heading, never merged into depaudit's counts or its verdict;
- it does not affect the command's exit code — a known CVE in a transitive dependency is not
  the same event as a malicious package and must not fail the same command;
- **host-side only.** `api.osv.dev` remains deliberately absent from
  `proxy/allowed_domains.txt`, and the "zero new egress surface" consequence above is still
  banked. Adding osv.dev to the allowlist is not the answer to anything here;
- `--ignore-until-fixed` is the survivability mechanism: it suppresses an ID only while no
  fix exists, so the finding returns by itself the day one lands. The ignore list lives in
  `profile.sh` beside the call, and an entry without a stated reason is not a decision.

**Also debunked, so nobody re-inherits it.** `UV_MALWARE_CHECK=1` — claimed by an outside
plan to enable an opt-in OSV malware lookup on every sync — **does not exist** through uv
0.12.5. Neither does any `malware` string in its help output. And the "4–10× faster than
pip-audit" figure that travelled with it is unverified decoration; do not repeat it.

**Re-open condition status.** The first condition above — *"pip/uv usage grows enough that
the missing Python age gate is the dominant risk"* — is now **answered without reopening
anything**. `exclude-newer` takes a timestamp and not a duration, which is why it could never
be an image-wide setting; but ADR-0003 makes `scripts/with-egress.sh` the only route a
dependency enters a profile by, and that script knows the moment each window opens, so it
does the duration→timestamp conversion per window and injects `UV_EXCLUDE_NEWER` at
now−7 days. Python gets the same relative quarantine npm has from `min-release-age=7`, with
no registry proxy, no image-wide resolution freeze and no per-project maintenance. Measured
2026-08-24 on uv 0.12.5: env beats a project `[tool.uv] exclude-newer`, and the variable is
inert under `--frozen`.

The third condition above — *"artifact-level inspection,
rather than name-level, becomes a requirement"* — has **partly fired**. `scripts/vendor-tools.sh`
now performs artifact-level content verification for every vendored payload: it extracts the
wheel and diffs it against the `source_commit` it claims, which a hash cannot answer. The
ADR's stated posture is therefore behind the code. This records that; it is not a decision to
reopen the registry-proxy question, because the artifact inspection that exists is over a
handful of vendored payloads we publish ourselves, not over the general dependency stream.

**Related but still refused:** PEP 740 / attestation verification. `pypi-attestations`
carries its own dependency tree, which is precisely what `depaudit`'s stdlib-only rule exists
to refuse. Unchanged.

## Alternatives considered

- **Build `depgate` as specified.** Rejected: it is a design for an environment without
  containment. Here it would duplicate Gate 4 in software while adding attack surface.
- **Adopt nothing and rely on the egress boundary alone.** Rejected: the allowlist gates
  hosts, not package names. Once a window is open, any package on the registry is
  reachable — which is the gap the age gate exists to close.
- **Defer all of it until a second person joins.** Rejected: the controls that matter most
  (a human naming each dependency; a quarantine window) are cheapest to adopt before
  habits set, and the autonomous-agent case is exactly the one with no human in the loop.
