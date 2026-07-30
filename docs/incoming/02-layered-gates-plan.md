# Layered Dependency Gates — Design Plan

**Codename:** `depgate`
**Scope:** Node + Python. Two deployment topologies: inside the egress container, and
client-side without it.
**Status:** Design. Not built.

---

## 1. The core architectural claim

There are five points at which a hallucinated package can be stopped. They are not
redundant — each catches what the others structurally cannot.

| Gate | Fires at | Catches | Bypassable? |
|---|---|---|---|
| **0 — Intent** | Agent proposes an install | The name before it's ever resolved | Yes — advisory to the model |
| **1 — Pre-resolution** | Before any network fetch | Nonexistent names, young packages, known-bad, cross-registry confusion | Depends on topology |
| **2 — Resolution** | Version selection | Anything inside the age quarantine window | No, if registry is pinned and egress is closed |
| **3 — Download, pre-execution** | Artifact fetched, scripts not yet run | Install-script payloads, integrity mismatches, sdists | No, at the proxy |
| **4 — Post-install** | After execution | Nothing — **detection only** | N/A |

**Gate 0 vs Gate 2 is the important distinction.** Gate 0 knows *intent* and can explain
itself to the model, so the agent self-corrects and the loop stays fast. Gate 2 knows
nothing about intent but cannot be argued with. You need both: the fast one for
ergonomics, the slow one because the fast one is advisory.

The egress container is what makes Gates 1–3 unbypassable. That is a materially stronger
position than most organizations have, and the design should exploit it rather than
replicate client-side controls into it.

---

## 2. Shared policy definition

One policy file, consumed by every gate in both topologies, and by `depaudit` from plan 01.
Without this the enforcement points drift and start disagreeing, which is worse than having
fewer of them.

```yaml
# policy.yaml — v1
version: 1

quarantine:
  default_days: 7          # blocks the opportunistic majority
  high_risk_days: 14       # single maintainer / recent ownership transfer / install scripts
  exempt_security_patches: true
  # Rationale: most malicious releases are caught and pulled within hours to a few days,
  # so a short window captures nearly all of them.

new_package:
  min_first_publish_age_days: 90   # for names never before seen in this org
  min_versions: 3
  require_repository_url: true
  max_maintainer_churn_days: 30

scripts:
  npm: block               # ignore-scripts; exceptions below
  python: wheels_only      # --only-binary :all:
  allow_scripts:
    - name: esbuild
      reason: "native binary download"     # required field — no bare entries
      approved_by: "@platform"
      expires: 2027-01-01                  # forces periodic re-justification

allowlist:
  internal_scopes: ["@ourco"]
  internal_index_hosts: ["pypi.internal.ourco.net"]
  packages: []             # append-only, PR-reviewed, reason required per entry

blocklist:
  packages:
    - { eco: npm, name: unused-imports, reason: "confirmed malicious slopsquat" }

signals:
  cross_ecosystem_name_collision: block
  llm_naming_pattern: review
  levenshtein_near_popular: review
  no_provenance_attestation: info

enforcement:
  local: warn              # start here
  ci: block
  container: block
  fail_mode:
    ci: closed
    local: open_loud       # see §6
```

Ship this as a versioned artifact in its own repo. Every gate reports the policy version it
enforced, so a finding can be traced to the rules in force at the time.

---

## 3. Gate implementations

### Gate 0 — Intent (agent layer)

Claude Code `PreToolUse`. The hook receives the tool call as JSON on stdin; exit 2 blocks and
feeds stderr back to the model as the reason, or exit 0 with a `hookSpecificOutput` block
carrying `permissionDecision` of `allow` / `deny` / `ask`. Prefer the structured form — the
same script can then approve, block with explanation, or hand the choice to you.

Use the `if` field to scope tightly. Broad matchers fire on every Bash call and the resulting
false positives are the single most common reason people disable hooks.

```jsonc
// .claude/settings.json
{
  "hooks": {
    "PreToolUse": [
      { "if": "Bash(npm install*)",  "args": ["./.depgate/hook-install.sh"] },
      { "if": "Bash(npm i *)",       "args": ["./.depgate/hook-install.sh"] },
      { "if": "Bash(pnpm add*)",     "args": ["./.depgate/hook-install.sh"] },
      { "if": "Bash(yarn add*)",     "args": ["./.depgate/hook-install.sh"] },
      { "if": "Bash(pip install*)",  "args": ["./.depgate/hook-install.sh"] },
      { "if": "Bash(uv add*)",       "args": ["./.depgate/hook-install.sh"] },
      { "if": "Bash(poetry add*)",   "args": ["./.depgate/hook-install.sh"] },

      // The agent editing a manifest directly bypasses every install matcher above.
      { "if": "Edit(package.json)",       "args": ["./.depgate/hook-manifest.sh"] },
      { "if": "Write(package.json)",      "args": ["./.depgate/hook-manifest.sh"] },
      { "if": "Edit(requirements*.txt)",  "args": ["./.depgate/hook-manifest.sh"] },
      { "if": "Edit(pyproject.toml)",     "args": ["./.depgate/hook-manifest.sh"] },

      // Docs are executable surfaces — an unverified name written here gets run later.
      { "if": "Write(AGENTS.md)",   "args": ["./.depgate/hook-docs.sh"] },
      { "if": "Write(CLAUDE.md)",   "args": ["./.depgate/hook-docs.sh"] },
      { "if": "Write(*.mdc)",       "args": ["./.depgate/hook-docs.sh"] }
    ]
  }
}
```

Three matcher families because there are three distinct evasion paths, and only the first is
obvious.

**Hook contract:**
- Extract package specs from the command or the manifest diff
- Call `depaudit pkg <eco> <name>` (same code path as the scanner — §9 of plan 01)
- **Latency budget: 2 seconds hard.** Warm cache, 10-way concurrency, and a timeout that
  degrades to `ask` rather than hanging. A hook that stalls the agent gets removed.
- Deny messages must be *actionable to a model*: name the real package if one is obvious,
  state the failing signal, and say what would make it pass. `"Blocked: not found on npm"`
  produces a retry loop. `"Blocked: 'unused-imports' not on npm; you likely mean
  'eslint-plugin-unused-imports' (8y old, 12M weekly)"` produces a correct fix.

**Other agents:**
- **Codex** — no hook system. Use `~/.codex/config.toml`: `sandbox_mode`, and
  `approval_policy` with any package install in the always-ask set alongside `curl | bash`
  and `sudo`. Coarser: gates the action, can't inspect the name.
- **Copilot / Cursor** — no equivalent deterministic gate. These rely entirely on Gates 1–3,
  which is the argument for the container topology.

**Do not rely on `CLAUDE.md` instructions as a control.** They're advisory; a model can
reason past them under task pressure. Hooks cannot be talked out of anything. Keep the
instructions — they improve first-attempt behavior and reduce how often the hook fires — but
count only the hook.

---

### Gate 1 — Pre-resolution (metadata gate)

Metadata only, no artifact touches disk. Implemented once, as an HTTP service:

```
POST /check
{ "ecosystem": "npm", "name": "foo-utils", "version": "^1.0.0", "context": "agent|ci|proxy" }

200 { "verdict": "allow|ask|deny",
      "signals": [{ "id": "first_publish_age", "value": 11, "threshold": 90 }],
      "message": "…", "policy_version": 1, "cache_hit": true }
```

Every other gate is a client of this endpoint. One decision engine, many call sites.

Checks in order (cheapest first, short-circuit on match): blocklist → allowlist →
existence → age/versions/repo/maintainer → cross-ecosystem collision → naming pattern →
Levenshtein → intel feeds.

---

### Gate 2 — Resolution (native package manager)

This is the highest-value control after the proxy, and it's now native across the Node
ecosystem. Values are **not** in the same unit per tool — a config generator is worth writing
rather than hand-maintaining these.

| Tool | Setting | File | Unit | Minimum version |
|---|---|---|---|---|
| npm | `min-release-age` | `.npmrc` | days | 11.10.0 (Feb 2026) |
| pnpm | `minimumReleaseAge` | `package.json` / `.npmrc` | **minutes** | 10.16 (Sep 2025) |
| Yarn Berry | `npmMinimalAgeGate` | `.yarnrc.yml` | minutes | 4.10.0 |
| Bun | `minimumReleaseAge` | `bunfig.toml` | — | 1.3 |
| uv | `exclude-newer` | `pyproject.toml` | timestamp | — |
| pip | **none** | — | — | proxy-enforced only |

Exemptions: pnpm `minimumReleaseAgeExclude` (names only), Yarn `npmPreapprovedPackages`
(globs and exact locators — more flexible).

**Three gotchas to design around:**

1. **The gate fires at install time, not at PR time.** Renovate and Dependabot evaluate
   updates independently of the package manager, so their cooldowns must be configured
   separately or they'll keep opening PRs that can't actually be installed. Renovate's
   `config:best-practices` preset already sets a 3-day npm default; Dependabot uses
   `cooldown.default-days` with per-semver overrides. Both exempt security updates.
2. **The gate cannot be scoped per registry.** Internal packages get held back along with
   everything else unless explicitly excluded — and npm has no exclusion list yet. In the
   container topology, solve this at the proxy instead: quarantine the public uplink, pass
   internal packages through immediately.
3. **Defaults are shifting.** pnpm 11 already enables this by default; npm v12 is expected
   to. Pin your versions and set the value explicitly rather than inheriting.

Also at this gate: **pin the registry** so resolution goes to the proxy, and in the
container topology, block direct registry egress so there's no route around it.

---

### Gate 3 — Download, pre-execution

The window where the artifact exists but hasn't run.

- **Script blocking.** npm `ignore-scripts=true`; Python `--only-binary :all:`. Note the
  ecosystem asymmetry: npm runs `postinstall` on install, while Python wheels don't execute
  at install at all — only sdists run `setup.py`, at build time. So wheel-only is a stronger
  guarantee than `ignore-scripts`, which merely defers.
  Expect breakage on `sharp`, `esbuild`, `bcrypt`, `puppeteer`, Prisma. Handle via the
  policy `allow_scripts` list with mandatory reason and expiry, plus explicit
  `npm rebuild <pkg>`. The friction is the feature: script execution becomes a named act.
- **Integrity verification** against the lockfile hash. Mismatch = hard fail, no prompt.
- **Tarball inspection** (container only): before releasing a cached artifact, scan the
  manifest for lifecycle scripts, look for high-entropy blobs, `eval` of fetched content,
  reads of `~/.npmrc` / `~/.aws` / `.env`, and outbound network in install paths.
- **Quarantine directory.** Artifacts land in a staging path; promotion to the shared cache
  requires passing inspection.

---

### Gate 4 — Post-install (detection)

Too late to prevent a `postinstall` payload. Design for detection and blast radius.

This is where the egress container earns the most: **a dependency install has an extremely
narrow legitimate network profile.** It talks to the registry and possibly one CDN. Anything
else — a novel domain, a paste site, an IP literal, DNS exfiltration patterns — during or
shortly after an install is high-signal, low-false-positive evidence. Very few controls in
this space are that clean.

- Egress deny-by-default during install windows, allowlisting registry + known CDNs
- Alert on first-seen domains correlated with install activity
- Credential canaries: fake tokens in `.env`, `~/.npmrc`, `~/.aws/credentials`, alert on use
- Filesystem diff of `node_modules` / `site-packages` against expected lockfile contents;
  files present that no package declares are a finding
- Retain the audit log: who requested what, when, from which environment, allowed or blocked.
  This is both the post-incident artifact and, increasingly, the compliance one.

---

## 4. Topology A — inside the egress container

The strong version. All traffic already routes through here, so this is where policy becomes
unbypassable.

```
 developer / CI / agent
          │  (registry + index pinned to proxy; direct registry egress DENIED)
          ▼
┌─────────────────────────────────────────────┐
│  egress container                           │
│                                             │
│  verdaccio ──┐                              │
│  (npm uplink)│                              │
│              ├──▶ depgate policy svc ──▶ metadata cache
│  devpi ──────┘         │  (Gate 1)          │
│  (PyPI uplink)         ▼                    │
│                   quarantine + inspect      │
│                      (Gate 3)               │
│                          │                  │
│                    artifact cache           │
│                          │                  │
│                    audit log ──▶ SIEM       │
│                                             │
│  egress firewall: registry domains only     │
└─────────────────────────────────────────────┘
          │
          ▼  registry.npmjs.org / pypi.org
```

**The critical design decision: run real registry proxies, don't MITM.**

Registry traffic is HTTPS. To apply per-package policy you either intercept TLS with a
corporate CA — brittle, breaks pinning, and hostile to debug — or you run a caching registry
proxy and point clients at it. Choose the proxy. You then see package names, versions, and
publish timestamps in cleartext at the application layer, which is exactly what policy needs.

- **npm:** Verdaccio (lightweight, plugin-friendly) or Nexus/Artifactory if already deployed
- **PyPI:** devpi (mirrors + quarantines well) or Artifactory
- Both configured uplink-only to the official registry, with the container firewall
  permitting egress *only* to those uplink hosts

**Why this is stronger than client config:** the proxy enforces the *organization's* policy
regardless of what any repo's `.npmrc` says, applies uniformly to pip which has no native age
gate, covers agents like Copilot that have no hook system, and produces a single audit log.
Nothing routes around it because there is no route.

**Quarantine at the proxy** replaces per-repo age gates as the authoritative control: hold
newly published upstream versions for N days before making them available, per policy, with
internal packages exempt. This also fixes Gate 2 gotcha #2, since the proxy *can* distinguish
public from internal.

**Bootstrapping problem, and it's real:** Verdaccio is an npm package; devpi is a PyPI
package. The tools guarding your supply chain arrive through your supply chain. Mitigations:
install at image build from digest-pinned artifacts, vendor them into an internal base image,
verify checksums out-of-band, and rebuild on a schedule rather than dynamically. `depgate`
itself is stdlib-only for exactly this reason (plan 01 §1).

**Container deliverables:**

```
/opt/depgate/
  policy.yaml               # mounted, versioned, PR-reviewed
  bin/depgate               # policy service (Gate 1)
  bin/depaudit              # scanner from plan 01, shares the code path
  cache/metadata/           # shared, TTL'd
  cache/artifacts/          # post-inspection
  quarantine/               # pre-inspection staging
  verdaccio/config.yaml
  devpi/
  audit/depgate.jsonl       # append-only, shipped to SIEM
```

Health/observability: `/healthz`, `/metrics` (checks by verdict, cache hit rate, p50/p99
latency, blocks by signal), and a daily digest of what was blocked.

---

## 5. Topology B — sans container

Every control moves client-side. Weaker in a specific, worth-stating way: **it is advisory
against a determined user.** `npm install --registry=https://registry.npmjs.org` bypasses
the pinned registry. There is no fix for that client-side; the answer is to make CI the
enforcement point, since CI is the one execution environment you fully control.

| Layer | Mechanism |
|---|---|
| Gate 0 | Same `.claude/settings.json` hooks — identical, portable |
| Gate 1 | `depgate` as a local binary + `~/.cache/depgate`, not a service |
| Gate 2 | Native package manager settings, committed per repo, generated from `policy.yaml` |
| Gate 3 | `ignore-scripts` / `--only-binary :all:` in committed config |
| Gate 4 | Largely unavailable — no egress visibility. Credential canaries and lockfile-diff review are what remain. |
| **Enforcement** | **CI.** Blocking status check on every PR: posture scan, lockfile-diff gate on new/changed dependencies, cooldown check. |

**Distribution and drift** are the hard parts here. A `policy.yaml` in one repo doesn't
propagate. Options, best first: an org-wide reusable CI workflow that every repo must call
(enforced by branch protection), a shared pre-commit hook repo pinned by rev, and a
`depgate init` command that writes the correct per-tool config from central policy. Then run
`depaudit posture` on a schedule across the estate to detect repos that have drifted — that
scheduled scan *is* the compensating control for the missing chokepoint.

**Coverage comparison:**

| Capability | Container | Sans container |
|---|---|---|
| Unbypassable resolution policy | ✅ | ❌ |
| Covers pip's missing age gate | ✅ | ❌ (proxy-only feature) |
| Covers hookless agents (Copilot) | ✅ | ❌ |
| Central audit log | ✅ | Partial (CI logs only) |
| Artifact inspection pre-execution | ✅ | ❌ |
| Install-time egress detection | ✅ | ❌ |
| Uniform policy without per-repo edits | ✅ | ❌ |
| Agent feedback loop (Gate 0) | ✅ | ✅ |
| Works for an offline laptop | Partial | ✅ |

Run both. The container is the enforcement backstop; client-side is the fast feedback layer
and the fallback when someone is on a plane.

---

## 6. Failure modes

Decide these explicitly now, because they'll be decided implicitly under pressure otherwise.

| Situation | Behavior |
|---|---|
| Policy service unreachable, **in CI** | **Fail closed.** A build that can't verify shouldn't ship. |
| Policy service unreachable, **locally** | **Fail open, loudly.** Warn, log, proceed. Fail-closed local tooling gets uninstalled within a week, and an uninstalled gate protects nothing. |
| Registry API 5xx / rate-limited | Serve stale cache up to 7 days; `UNKNOWN` beyond that, which maps to `ask` |
| Legitimate urgent security patch inside quarantine | Documented break-glass: `DEPGATE_OVERRIDE=<ticket>`, logged, expires in 24h, alerts the security channel. Without this path people disable the whole system for one emergency. |
| Hook exceeds latency budget | Degrade to `ask`, never hang |
| False positive on an internal package | `depgate allow` writes to the repo allowlist; PR-reviewed; reason mandatory |

---

## 7. Rollout

Never start in blocking mode. The first week's false-positive rate determines whether this
survives.

| Phase | Duration | Mode | Exit criteria |
|---|---|---|---|
| 1. Observe | 2 weeks | Log only, everywhere. Proxy passes everything through. | Baseline established; false-positive rate measured; noisy signals tuned |
| 2. Warn | 2 weeks | Gate 0 warns; CI annotates but doesn't fail | FP rate < 2% of installs; allowlist stabilized |
| 3. Block new | 2 weeks | Deny `BLOCK`-tier only (404s, known-malicious, cross-ecosystem). Quarantine on. | Zero legitimate workflows broken |
| 4. Block review-tier in CI | ongoing | CI fails on `REVIEW` without an allowlist entry; local still warns | — |
| 5. Full | ongoing | Script blocking on, wheels-only on, egress deny-by-default during installs | — |

Sequence Gate 0 first regardless of topology. It's an afternoon of work, it covers the
autonomous-install path which is the acute risk, and it produces the telemetry that tells
you where to set thresholds for everything else.

---

## 8. Metrics

- **False-positive rate per 100 installs** — the number that decides adoption. Track weekly.
- Blocks by signal — which signals earn their keep; retire the ones that only ever fire wrong
- Gate 0 hit rate — how often the agent proposes something that fails. A declining trend
  means instructions and model behavior are improving; a spike is worth investigating.
- p99 hook latency
- Allowlist growth rate — steady growth is fine, sharp growth means thresholds are wrong
- Quarantine catch count — versions blocked that were later unpublished upstream. This is the
  clearest evidence the system prevented something, and worth reporting upward.
- Estate posture coverage from `depaudit fleet`

---

## 9. What this does not solve

Stated plainly so it isn't discovered later.

- **A patient squatter.** Age gates and quarantine assume the malicious version has a short
  live window, which holds for compromised popular packages caught within hours. A squatted
  name has no users watching it: an attacker registers it, waits out the window, and it ages
  into apparent legitimacy. Cooldowns don't help against typosquatting or against attacks
  that don't involve publishing a new version.
- **Compromise of an already-trusted, already-allowlisted dependency.** Different threat
  model, different controls.
- **A malicious first-party commit.** CODEOWNERS and review, not this system.

The residual risk after all five gates is a *patient, well-resourced attacker who registers a
plausible name and waits months*. The only control that catches that is a human deliberately
choosing each new dependency and being accountable for the choice. Everything above exists to
make sure that decision is never skipped by accident — not to replace it.
