# Dependency Guardrails — Implementation Plan

**Status:** IN PROGRESS. **Phases 0 and 1 complete; phase 2 config half complete
(T07–T12, T24, T09, T11) — 2026-07-31.** Remaining: `depaudit` (T13–T16), phase 3, phase 4.
Prerequisites T00/T01 discharged — see §0.1.
**Exit rule:** this folder is deleted, or moved to `work/archive/`, when the work merges.
**Owner decision gate:** §13. Five decisions need an answer; four of them only block later phases.

**Inputs (RFC tier):**
[`01-posture-scanner-plan.md`](../../docs/rfcs/01-posture-scanner-plan.md) (`depaudit`) ·
[`02-layered-gates-plan.md`](../../docs/rfcs/02-layered-gates-plan.md) (`depgate`) ·
[`DEPENDENCY_GUARDRAILS.md`](../../docs/rfcs/DEPENDENCY_GUARDRAILS.md) ·
[`04-portable-guardrails-outside-sandbox.md`](../../docs/rfcs/04-portable-guardrails-outside-sandbox.md)
(the host-side subset, out of scope here).
Prose below refers to these as "plan 01", "plan 02", "plan 04".

**Evidence labelling.** Every load-bearing claim is marked:
**[C]** Confirmed — verified in this tree or a live probe, with the date ·
**[I]** Inferred — plausible, needs validation before it is relied on ·
**[D]** Needs-decision — a human must choose.

Claims marked **[C 07-31]** were verified on 2026-07-31 — against the working tree, or by
live probe against the image and the three running profiles. A few **[C 07-30]** claims
remain from the original probe run where re-running them was not warranted; each is noted.
**Prerequisites T00 and T01 are complete — see §0.1.**

---

## 0. What changed since the 2026-07-30 draft

One material fact moved, and it improves the plan.

**[C 07-31]** Commit `fc7c0f0` ("chore(proxy): disable pypi, npm, numerai, kaggle and
VS Code marketplace tags") commented out the `[pypi]`, `[pytorch]`, `[npm]`, `[nvidia]`,
`[numerai]`, `[kaggle]` and `[vscode]` blocks in `proxy/allowed_domains.txt`. **The package
registries are closed right now.** 53 domains are active; `registry.npmjs.org`,
`.pypi.org`, `.files.pythonhosted.org`, `.astral.sh` and `download.pytorch.org` are not
among them.

Three consequences, all of which make the plan cheaper:

1. **Phase 2b is no longer a build, it is a formalisation.** The draft proposed
   constructing a `locked` mode and defaulting to `dev` "to avoid breaking the running
   profiles". The running profiles are *already* locked, by hand. The work is to make that
   state named, per-profile, and documented — not to invent it.
2. **The recommended default inverts.** `locked` is the observed status quo; `dev` becomes
   the opt-in. Defaulting to `dev` would now *widen* egress relative to what is deployed.
3. **`with-egress.sh` became the only install route, so phase 3 got more valuable.**
   Previously the window was one of two ways to install; now every install must pass
   through it. Instrumenting it therefore captures 100% of installs rather than an unknown
   fraction. This is the single strongest argument in the plan for doing phase 3.

**[C 07-31] Stale documentation, now a defect.** `proxy/allowed_domains.txt` lines 11–17
still state that "package registries + CDNs are uncommented by default (unlike macolima,
where they live in PLANNING-MODE and are commented)". That is no longer true of this file.
An agent reading the header learns the opposite of the deployed posture. Fixed in T09.

**[C 07-31] Verified in the running proxies, not just the file.** With all three profiles
up, `registry.npmjs.org` and `pypi.org` both return `000` from inside a sandbox. The
registries are closed in enforcement, not only on paper.

---

## 0.1 Prerequisite results (T00, T01 — both run 2026-07-31)

**T00 — baseline re-taken. A1 validated, with drift.** The 07-30 probe was one day stale
and three of six values had moved:

| | 07-30 | 07-31 | Bar |
|---|---|---|---|
| npm | 12.0.1 | **12.0.2** | ≥ 11.10.0 ✓ |
| node | 24.18.0 | **24.18.1** | — |
| uv | 0.11.29 | **0.12.0** | — ✓ |
| pnpm / pip / python | 10.34.5 / 24.0 / 3.12.3 | unchanged | ≥ 10.16 ✓ |

Gate 2 remains entirely unconfigured: `min-release-age = null`, `allow-scripts = [""]`,
`save-exact = false`, pnpm `minimumReleaseAge` undefined, no `/etc/pip.conf`.

Two findings that firm up phase 2:
- **[C 07-31]** `npm config get globalconfig` = **`/usr/etc/npmrc`** — T07's target path is
  correct; the file does not exist yet.
- **[C 07-31]** `min-release-age-exclude = []` exists in npm 12, so §11's per-package
  escape hatch is real rather than assumed.

**Re-run T00 before starting phase 2.** Versions moved measurably in 24h; today's numbers
should not be trusted next week.

**T01 — G1 REFUTED. See §6 G1 and §12.** `squid -k reconfigure` does not kill the proxy.
The prerequisite is discharged and phase 3 is unblocked; T17 is dropped.

**G9 discovered while verifying T01 — see §6 G9.** All three running proxies were serving a
stale, inode-pinned allowlist permitting a domain the repo had gated. Cleared by bringing
the profiles down and up; **[C 07-31]** all three now diff clean against the host file at
53 domains.

---

## 1. Problem and intended outcome

**Problem.** Slopsquatting is a supply-chain attack aimed specifically at AI-generated
code: models invent plausible package names, attackers pre-register them with a malicious
`postinstall`, and an agent installing autonomously completes the attack with no human in
the loop. Per plan 01 and `DEPENDENCY_GUARDRAILS.md` §1, roughly 1 in 5 AI-recommended
packages does not exist, ~43% of hallucinated names recur across prompts (so they are
squattable at scale), and about half resemble nothing real — meaning typo/similarity
scanners structurally cannot catch them. **[I]** — these figures come from the imported
RFCs and are not independently verified here; they motivate the work but nothing in the
design depends on their precision.

**This repo's actual position.** The expensive control is already paid for and the cheap
one is missing. `internal: true` + DNS sinkhole + Squid allowlist means a malicious
`postinstall` has no route to an attacker-controlled host — plan 02's Gate 4, which it
describes as the hardest to obtain, is *structural* here rather than aspirational. What is
missing is the config-level gate that any of the installed tools already supports.

**Intended outcome.** A dependency cannot enter a profile without (a) a human naming it,
(b) a quarantine window having elapsed, and (c) a record of what the install window did.
Three properties, in priority order:

1. **Adding a dependency is a deliberate, named human act** — not a side-effect of an
   agent editing a manifest and running an allowed build command.
2. **Freshly-published packages cannot resolve** for a quarantine period, which is the one
   control that covers the window where every threat-intel feed structurally fails: the
   hours-to-days between an attacker publishing and anyone detecting it.
3. **Every install window leaves an auditable record** — what was requested, what egress
   occurred, what appeared on disk — retained on the host, not on tmpfs.

**Non-outcome, stated plainly.** None of this defeats a patient squatter who registers a
plausible name and waits out the quarantine, nor the compromise of an
already-trusted dependency. Only property 1 touches those, and only by making a human look.

---

## 2. Verified evidence — where the five gates stand

Gate model from plan 02 §3. Container-side tool versions re-probed **2026-07-31** (T00,
§0.1): npm 12.0.2 / pnpm 10.34.5 / node 24.18.1 / uv 0.12.0 / pip 24.0 / Python 3.12.3.

| Gate | Mechanism | State | Evidence |
|---|---|---|---|
| **0 — Intent** | Agent refuses / surfaces the name | ✅ **CLOSED 07-31 (phase 1)** — deny list symmetric (87 entries), manifest-edit path blocked by hook rule 13, docs path warn-logged by rule 14 | **[C 07-31]** `claude-settings.json`; `deny-destructive.sh`; suite 79/79 |
| **1 — Pre-resolution** | Metadata check before resolving | ❌ **Absent** | no equivalent |
| **2 — Resolution** | Age gate + pinned registry | ❌ **Absent in config, present in every tool** | **[C 07-30]** `min-release-age = null`; pnpm `minimumReleaseAge` undefined; no `exclude-newer` |
| **3 — Download, pre-exec** | Script blocking | ✅ **npm by default** (`allow-scripts = [""]`) · ❌ **Python open** — sdists run `setup.py` | **[C 07-30]** `npm config ls -l`; **[C 07-31]** no `pip.conf` in repo or image |
| **4 — Post-install** | Egress deny-by-default | ✅ **Structurally solved**, ❌ operationally unused — log is tmpfs, unread | **[C 07-31]** `docker-compose.yml`; `proxy/squid.conf:34-40` |

### 2.1 What the egress model buys

**[C 07-31]** `proxy/squid.conf:40` writes `access_log stdio:/var/log/squid/access.log`;
lines 34–36 document the mount as tmpfs, "intended for in-session forensics, not long-term
storage". Combined with `internal: true` and `dns: [127.0.0.1]`, a `postinstall` that
phones `evil-cdn.example` gets `TCP_DENIED` and dies. Plan 02 treats this as a *detection*
claim; here it is a *prevention* claim.

### 2.2 What it does not buy — three honest caveats

- **[C 07-31] The allowlist contains write-capable, credential-reachable hosts.**
  `github.com`, `api.github.com` and `codeload.github.com` are active, and
  `/root/.config/gh` holds a token. A payload that reads that token and pushes a gist stays
  entirely inside the allowlist. `deny-destructive.sh` rule 9 (`cred-read`) constrains the
  *agent*, not a `postinstall` script, which runs outside the Claude tool boundary.
- **The proxy sees CONNECT, not payloads.** An allowlisted `registry.npmjs.org` means *any*
  npm package is fetchable. The allowlist gates hosts; it cannot gate package names. That
  is precisely the gap Gate 2 fills — and note this caveat is currently dormant, because
  the registry is closed (§0).
- **[C 07-31] The interactive shell is ungated.** `claude-settings.json:2` says so in its
  own header: "Interactive zsh is unrestricted". Every control in the deny list is a
  control the human's own shell does not have. Deliberate, documented, and the reason
  config-level gates (§6 G5) matter more than deny-list entries.

---

## 3. Scope and non-goals

**In scope:** everything that runs on this host or inside these profiles — the agent deny
list, the `PreToolUse` hook, image and per-profile package-manager config, the Squid
allowlist lifecycle, `with-egress.sh` instrumentation, and a host-side read-only scanner.

**Out of scope, with reasons:**

| Not in scope | Why | Where it lives |
|---|---|---|
| Host-wide / other-repo guardrails | Different threat model — no egress boundary, no window | plan 04; no owning work item yet |
| CI enforcement | **[C 07-31]** no CI in this repo | plan 04 §3 |
| `depgate` as specified in plan 02 | Built for an org with a fleet and no containment | ADR-0002 (proposed) |
| Cross-port to macolima | Follows this work, does not gate it | §13 D5 |

**Explicitly not built** — full rationale in `docs/adr/0002-dependency-guardrail-scope.md`
(Proposed): Verdaccio/devpi inside the egress container, Gate 1 as an HTTP policy service,
SARIF output, fleet mode, `policy.yaml` as a separate versioned artifact, Socket Firewall
(`sfw`), Socket `batchPackageFetch`, the `osv-scanner` binary, and a local OSV mirror.

---

## 4. Assumptions and open questions

**Assumptions [I] — validate before relying on them:**

- **A1. ✅ VALIDATED 2026-07-31 (T00).** Versions drifted upward but every bar is still
  cleared. Re-validate before phase 2 — see §0.1.
- **A2.** `min-release-age` in npm 12 does not interact badly with the
  `--allow-scripts=@anthropic-ai/claude-code` build step at `Dockerfile:365`. **[C 07-31]**
  that line exists and is load-bearing — it is what keeps `claude --version` from
  reporting "native binary not installed". T08 validates this explicitly; it is the single
  most likely way phase 2 breaks the image.
- **A3.** Setting `min-release-age` does not break `npm run` / `pnpm run` for already-
  resolved trees. Expected, since the gate applies at resolution, not execution.
- **A4.** The `MAL-` prefix filter on OSV remains the correct BLOCK discriminator. Verified
  live once (§5 D6); OSV could in principle change its ID scheme.

**Open questions [D] — see §13 for recommendations.** D1 egress default · D2 quarantine
window · D3 `depaudit` home · D4 second intel source · D5 macolima port timing.

**Resolved by evidence, previously open:** whether to default `locked` or `dev` was framed
in the draft as a coin-flip; §0 settles the *observed* state, which makes `locked` the
status quo rather than a change. It remains a decision (D1) but no longer a symmetric one.

---

## 5. Design decisions

Carried forward from the draft, with D7 added.

**D1 — One implementation, two invocation contexts.** Plan 01 §9's rule holds but the
contexts differ here: *scanner (host, networked)* and *install-window pre-flight (host,
networked)*. Nothing runs inside the agent container, which cannot reach a registry API
except through Squid and only when a section is open. `depaudit` stays host-side.

**D2 — stdlib-only is house style, not preference.** Plan 01 §1: a supply-chain tool must
not have a supply chain. **[C 07-31]** `sandbox_templates/bin/webfetch` already follows
this pattern. `depaudit` follows it. No exceptions.

**D3 — Where config lives decides whether it survives.** Per the AGENTS.md state table:

| Config | Path | Persistence | Verdict |
|---|---|---|---|
| npm global | `/usr/etc/npmrc` (`prefix=/usr`) | image layer | ✅ rebuilt from Dockerfile |
| npm user | `/root/.npmrc` | writable layer | ❌ lost on `docker rm` |
| pnpm global | `/root/.config/pnpm/rc` | **bind-mounted per profile** | ✅ persists, host-editable |
| pip | `/etc/pip.conf` | image layer | ✅ |
| uv | `pyproject.toml` per project | workspace, in git | ✅ correct home for `exclude-newer` |

npm and pip config go in the image; pnpm config goes in per-profile state; uv
`exclude-newer` stays per-project — an image-wide resolution freeze on an ML sandbox is a
footgun, not a control. The agent is root and can edit `/usr/etc/npmrc`; that is fine, and
the answer is the one this repo already uses — a **tier-1 tripwire** asserting live values
on every `up`, so drift surfaces within one cycle.

**[C 07-31] The insertion point for the pnpm half already exists.**
`scripts/init-profile-state.sh:27` creates `$BASE/config/pnpm`, and lines 39–40 write
`manage-package-manager-versions=false` using exactly the idempotent idiom T06 needs:

```sh
if ! grep -qs '^manage-package-manager-versions=' "$BASE/config/pnpm/rc"; then
  printf 'manage-package-manager-versions=false\n' >> "$BASE/config/pnpm/rc"
```

**D4 — The install window is the design centre.** **[C 07-31]** `with-egress.sh` is a
named, locked (`/tmp/with-egress.locks`), sentinel-tracked event that opens a tagged
allowlist section, runs one command, and closes it. Plan 02 spends a page arguing for
"egress deny-by-default during install windows" as an aspiration. We have the window — and
per §0 it is now the *only* route to a registry.

**D5 — Sibling-repo portability constrains the shell.** **[C 07-31]**
`deny-destructive.sh` is `#!/bin/sh`. New rules stay POSIX sh, bash-3.2-safe: no `[[`, no
arrays, no `${var,,}`. (`with-egress.sh` is bash and may use `[[`; the constraint is
per-file.)

**D6 — Threat-intel: OSV only, `MAL-` only, host-side.** Plan 01 §6 names OSV as an
`enrich` source; plan 01 §7 lists CVE output as an explicit *non-signal*. Both are right,
and the `MAL-` prefix is what reconciles them. **[C 07-30]** verified live against
`POST https://api.osv.dev/v1/querybatch`, unauthenticated:

| Query | Response |
|---|---|
| `pkg:npm/express@4.18.0` | `GHSA-qw6h-vgh9-j6wx`, `GHSA-rv95-896h-c2vc` |
| `pkg:pypi/requests@2.31.0` | 3× `GHSA-`, 3× `PYSEC-` |
| `pkg:npm/unused-imports@1.0.0` | **`MAL-2025-48781`** — "Malicious code in unused-imports (npm)" |

`unused-imports` is plan 01 §10's known-bad corpus entry; `express`/`requests` are its
known-good. Consume `MAL-`; discard `GHSA-`/`PYSEC-`/`CVE-` on this path entirely. Four
implementation facts the design depends on, all **[C 07-30]**:

- **Name-only queries work** — `{"package":{"name":"unused-imports","ecosystem":"npm"}}`
  returns the same hit as the versioned purl, so the check is usable *pre-resolution*.
- **`querybatch` returns only `{id, modified}`** — no `withdrawn`. Getting it needs
  `GET /v1/vulns/{id}` (verified `withdrawn: null` on the live `MAL-2025-48781`). Shape:
  batch → filter to `MAL-` → hydrate only the hits. Hits are rare; the second hop is free.
- **`withdrawn` must be honoured.** The reported May 2026 withdrawal of 157 records that
  wrongly flagged FastAPI, Strawberry GraphQL and rdflib is **[I]** unverified — but the
  design response holds regardless and the field exists to act on.
- **[C 07-31] Host-side means zero egress cost.** `api.osv.dev` is not in
  `allowed_domains.txt`. Per D1 `depaudit` runs host-side, so **no allowlist change is
  needed** and the cross-check adds no exfil surface to any profile. Preserve that: if it
  ever moves in-container, it stops being free.

Normalize on **purl** (`pkg:npm/name@version`) as the internal identifier. OSV takes it
directly; deps.dev and the GitHub Advisory API map cleanly.

**Secondary source, deferred:** the GitHub Advisory REST API
(`GET /advisories?type=malware&ecosystem=npm`) publishes from the npm security team and
often leads OSV. **[C 07-31]** `api.github.com` is already allowlisted, so it too costs no
egress surface. Trap worth recording: **responses exclude malware unless `type=malware` is
passed explicitly.** Phase 4+ — a latency optimisation on a source we already get.

**D7 — The allowlist is the registry gate; the age gate is the name gate.** New, forced by
§0. With registries commented out, resolution is impossible outside a window — which is
what plan 02 spends a registry proxy to buy. It gates *when*, not *which*. The two
controls are complements and neither substitutes for the other: `locked` stops an
unattended agent resolving anything; `min-release-age` stops a *human-opened* window
pulling something published this morning. Phase 2a is not redundant with §0.

---

## 6. The gaps, ranked

### G1 — ~~`with-egress.sh` reloads Squid with a signal that kills it~~ **REFUTED, CLOSED**

**[C 07-31] T01 disproved this. T17 is dropped and phase 3 is unblocked.**

The claim was that `scripts/with-egress.sh:97`'s `docker exec egress-proxy-$profile squid
-k reconfigure` kills the proxy, per commit `3809791`'s premise that squid runs as the
container's foreground PID and takes SIGHUP as Hangup, exiting 129.

Measured directly against `egress-proxy-fluidmomenta` (idle profile; image digest-pinned
`ubuntu/squid:latest@sha256:6a097f68…`, so this is not image drift):

```
docker exec … squid -k reconfigure  → exit 0, logs "Processing Configuration File"
timeout 6 docker wait               → rc 124 (never stopped)
docker inspect                      → running, exit=0, restarts=0
```

**Root cause of the misdiagnosis: squid is not PID 1.**

```
PID 1  /bin/bash /usr/local/bin/entrypoint.sh -f /etc/squid/squid.conf -NYC
PID 42 /usr/sbin/squid -f /etc/squid/squid.conf -NYC     ← child of PID 1
```

SIGHUP reaches squid, squid handles it as a reconfigure, PID 1 is untouched. The proxy kept
serving correctly afterwards (`api.anthropic.com` tunnelled, `example.com` denied).

**[C 07-31]** The inode half also does not apply to this script: `open_section` writes in
place and `cleanup` uses `cp backup "$ALLOWLIST"`, both preserving the inode the running
proxy is pinned to. **Neither half applies, so there is no bug in `with-egress.sh` to fix.**

The exit-129 the dashboard observed remains unexplained — most likely a proxy already dead
of another cause, or a parse failure on a half-written allowlist. The dashboard's *fix*
(restart, not reconfigure) is still correct, but for the G9 reason below, not this one.
**[C 07-31]** `dashboard/AGENTS.md` and `dashboard/src/lib/docker_client.py` state the
refuted mechanism in comments and should be corrected — **out of scope here; its own change.**

### G2 — Gate 0 is asymmetric across package managers

**[C 07-31]** Denied: `npm install`, `npm ci`, `npx`, `pip install`, `pip3 install`,
`python -m pip`, `python3 -m pip`, `uv add`, `uv pip install`, `uv tool install`, `uvx`,
`pipx`, `cargo install`, `go install`, `go get`.

**[C 07-31]** Not mentioned, so they fall through to `defaultMode: auto` — a *prompt*:

| Command | In image? |
|---|---|
| `pnpm add`, `pnpm install`, `pnpm dlx` | ✅ pnpm 10.34.5 |
| `uv sync`, `uv lock` | ✅ resolves + installs from `pyproject.toml` |
| `poetry add`, `yarn add`, `bun add` | ❌ absent — cover anyway, cheap |

`pnpm add` is the sharpest edge: pnpm is installed and **[C 07-31]** `Bash(pnpm run:*)` is
already on the *allow* list (line 70).

### G3 — Manifest edits bypass every install matcher

**[C 07-31]** `deny-destructive.sh`'s `Edit|Write|MultiEdit` branch (line 69) guards three
path families — `/usr/local/lib/claude-hooks/`, `/root/.claude/settings.json`,
`/etc/claude/` — plus `.git/hooks/` (line 86), then `emit_pass` at line 88. Everything else
passes. An agent that writes a dependency line into `package.json` and runs an
already-allowed `uv run` or `pnpm run build` has installed a package without ever issuing
an install command. **The most under-covered path in the system.**

### G4 — Docs are an executable surface and are unguarded

**[C 07-31]** `scripts/sync-agent-notice.sh` propagates a managed block from
`sandbox_templates/common/agent-notice.md` into repo `AGENTS.md` files and the global
`CLAUDE.md`. An unverified install command written into that template is distributed to
every repo the notice syncs into — a fan-out path the imported plans do not contemplate.

### G5 — Gate 2 is available everywhere and configured nowhere

| Tool | Setting | Present | Min required | Configured? |
|---|---|---|---|---|
| npm | `min-release-age` (**days**) | 12.0.1 | 11.10.0 | ❌ `null` |
| pnpm | `minimum-release-age` (**minutes**) | 10.34.5 | 10.16 | ❌ undefined |
| uv | `exclude-newer` (timestamp) | 0.11.29 | — | ❌ unset |
| pip | none native | 24.0 | — | N/A — proxy-only |

Every version bar is cleared **[C 07-30]**. This is a config file.

Config gates have a property the deny list structurally cannot have: **they are
invocation-path independent.** `claude-settings.json:42` concedes this in its own comment —
denies "can be routed around by wrapper commands (env, xargs, find -exec, make targets,
language interpreters)" — and **[C 07-31]** `Bash(make:*)`, `Bash(just:*)`,
`Bash(npm run:*)`, `Bash(pnpm run:*)`, `Bash(uv run:*)` are all on the *allow* list
(lines 64–78). An `.npmrc` gate fires regardless of which reached the installer, and fires
for the human in `zsh` too.

### G6 — Python has no script gate at all

npm 12 blocks lifecycle scripts by default; Python does not. Any sdist that resolves runs
`setup.py` at build time. Plan 02 §Gate 3 notes wheels-only is *stronger* than
`ignore-scripts` — and it is also the highest-friction control to impose on a CUDA/ML
image. Phase 4, data-driven.

### G7 — The proxy audit trail is tmpfs and unread

**[C 07-31]** `squid.conf:40` + the tmpfs mount. Nothing tails it, retains it, or
correlates it with install activity. The most valuable signal this architecture produces is
discarded on every proxy recreate.

### G8 — The allowlist header contradicts the allowlist *(new, §0)*

**[C 07-31]** `proxy/allowed_domains.txt:11-17` documents registries as uncommented by
default; `fc7c0f0` commented them out. Documentation that inverts the deployed posture is
worse than none, because it is what an agent reads before deciding whether an install can
work.

### G10 — a project `.npmrc` silently overrides the global quarantine *(new, 2026-08-01)*

**[C 08-01]** npm/pnpm config precedence is `cli > env > project > user > global`. Our Gate 2
values live in `/usr/etc/npmrc` (**global**), so **any repo under `/workspace` can switch the
quarantine off for itself** by shipping an `.npmrc` — without touching anything this sandbox
owns, and with no signal. Measured: a project file containing `min-release-age=0` takes
`npm config get min-release-age` from `7` to `0` inside a running profile.

This is not hypothetical here. `~/repo/therapod` carries three:

| File | Value | Effective state |
|---|---|---|
| `app_blast/.npmrc` | `minimum-release-age=0` | quarantine **OFF** |
| `app_zero/.npmrc` | *(not set)* | inherits our **10080** ✅ |
| `engine/.npmrc` | `minimum-release-age=0s` | **BROKEN — rejects every version** |

`0s` is worse than off. pnpm computes the cutoff as `value * 60 * 1e3`, so a suffixed
string yields `NaN` and `new Date(NaN)` = **Invalid Date**; every comparison against it is
false, so pnpm rejects *every* version and nothing resolves at all. It fails closed and
presents as a broken registry. **[C 08-01]** verified in-image with node.

Covered by T12 as a `warn` (not `fail`) — the workspace is the user's own repo and may have
a considered reason. Also the precise shape plan 01's `N01`–`N04` posture checks exist for,
so `depaudit` (T13) should report it per-repo rather than only per-profile.

### G9 — a running proxy can silently enforce a different allowlist than the repo *(new, replaces G1)*

**[C 07-31] Found live on all three profiles while verifying T01.** The host file and the
container's view had diverged:

```
host      proxy/allowed_domains.txt        inode 299417  size 15430
container /etc/squid/allowed_domains.txt   inode 523432  size 14930
```

The bind mount was pinned to a **deleted inode** — the file as it existed when the proxy
started. An atomic-replace edit on the host (an editor, `sed -i`, a git checkout) writes a
new file and renames over the old one, so a long-running proxy keeps serving the previous
content indefinitely.

**The delta was security-relevant and in the wrong direction.** All three proxies were
permitting `sheets.googleapis.com`, a domain the repo deliberately gated in commit
`ee40ee4`. It was the only difference — the registries were correctly closed in both — but
a domain removed from the allowlist stayed reachable for hours and **nothing reported it**.
Cleared by `down` + `up`; **[C 07-31]** all three now diff clean at 53 domains and
`sheets.googleapis.com` returns `000` from inside a sandbox.

This is the inode half of the bug commit `3809791` described, which G1 correctly ruled out
for `with-egress.sh` — it arrives through hand edits and git operations instead, which is
how the allowlist actually changes. `squid -k reconfigure` cannot fix it either: squid
re-reads the *path*, which still resolves to the pinned inode. Only a container restart
re-resolves the mount.

**This is a better task than T17 was.** Silent divergence between a security control's
source of truth and its enforcement is exactly what a tier-1 tripwire exists to catch, and
the check is a two-line diff. Becomes **T24**.

---

## 7. Implementation

Five phases. **Phases 0, 1 and 2 are independent and independently shippable — do not
sequence them behind the later ones.** Per plan 02 §7, nothing starts in blocking mode
except T04/T05, which block because a dependency addition should always be a named human
act, not because a signal fired.

### Phase 0 — Behavioural rules *(~1h, no infrastructure)*

**T02 — Inline the rules into the agent notice.**

- File: `sandbox_templates/common/agent-notice.md`
- Take `DEPENDENCY_GUARDRAILS.md` §2 and compress to five lines: never add a dependency
  silently; verify existence and provenance before proposing; prefer lockfile-strict
  installs; installation is privileged in autonomous mode; **install commands in
  agent-instruction files are subject to the same verification as manifest entries**.
- That last line closes G4 *in the file that is itself the fan-out vector* — do it in the
  same pass, not later.
- Run `scripts/sync-agent-notice.sh` to distribute.
- Plan 02 is explicit that instructions are advisory and must not be counted as a control.
  They earn their place by improving first-attempt behaviour and reducing how often the
  real gates fire.

### Phase 1 — Close the Gate 0 holes ✅ **COMPLETE 2026-07-31**

All four tasks landed. Suite: **79 passed, 0 failed** (was 61). Hook verified POSIX-clean
under `dash` (D5), so it cross-ports to macolima.

**T03 — Symmetry in the deny list** *(G2)*. ✅ **DONE.** File:
`sandbox_templates/claude/claude-settings.json`, deny list 74 → 87 entries. Added `pnpm
add/install/dlx`, `yarn add/install`, `bun add/install`, `uv sync`, `uv lock`, `poetry
add/install/lock`, `cargo add`. Original spec:

```
Bash(pnpm add:*)    Bash(pnpm install:*)   Bash(pnpm dlx:*)
Bash(yarn add:*)    Bash(bun add:*)        Bash(bun install:*)
Bash(poetry add:*)  Bash(uv sync:*)        Bash(uv lock:*)
```

`uv sync` / `uv lock` are the debatable pair — they are reproduce-the-lockfile operations,
which `DEPENDENCY_GUARDRAILS.md` §2.3 endorses as the safe form. Deny anyway: `uv sync`
will happily resolve a `pyproject.toml` the agent just edited (G3), making it an install
command in a lockfile costume. Reconsider allowing `uv sync --frozen` specifically once
T06 lands.

**T04 — Manifest rule in the hook** *(G3)*. ✅ **DONE**, as hook rule 13. File:
`sandbox_templates/claude/hooks/deny-destructive.sh`.

**Shipped design differs from the sketch below, because the sketch fails the merge gate.**
A regex over the payload alone cannot tell a dependency *addition* from a version *bump*:
an Edit whose `new_string` is `"left-pad": "1.0.1"` matches it exactly as well as one
adding `"lodash": "^4.17.21"`. Implemented instead as a **set difference**: `dep_names()`
extracts dependency names from the manifest **on disk** and from the payload, and only
names absent from the file block. A bump leaves the name set unchanged, so it passes.
Comparing against the file rather than `old_string` matters — an Edit payload is only a
fragment and cannot tell you what the manifest already holds.

One bug found by the merge-gate test during implementation: the first extraction was
line-oriented and silently returned nothing for compact manifests
(`{"a":"^1","b":"^2"}`, `dependencies = ["x>=1", "y>=2"]`). An empty *old* set makes every
existing dependency look new, which fired the rule on version bumps. Fixed by normalising
on `{}[],` first. **The failing merge gate is what caught it** — exactly the argument for
making it a gate. Original sketch, kept for the record:

```sh
case "$(basename "$rp")" in
  package.json|pyproject.toml|requirements*.txt|Pipfile)
    new=$(printf '%s' "$envelope" | jq -r '
      [ .tool_input.new_string?, .tool_input.content?,
        (.tool_input.edits? // [])[].new_string? ] | map(select(.)) | join("\n")' 2>/dev/null)
    printf '%s' "$new" | grep -Eq '"[a-z0-9@._/-]+"[[:space:]]*:[[:space:]]*"[\^~>=<0-9*]' \
      && emit_block "manifest-dep-add" \
           "adding a dependency to $(basename "$rp") is a trust-boundary change; surface the package name, purpose, and why an existing dep won't do"
    ;;
esac
```

POSIX sh per D5. The `emit_block` reason is written *for a model to act on*, per plan 02
§Gate 0: it states the rule, the why, and the alternative — not just "denied".

**T05 — Docs rule** *(G4)*. ✅ **DONE 2026-07-31, but as a WARN — deviation from this
plan, flagged for your call.**

The plan specified *block*. Implementing it showed that is wrong: documentation **about**
dependency rules legitimately quotes install commands. `agent-notice.md` — the file phase 0
just wrote, the one that carries rule 5 — contains `npm ci`, `pnpm install
--frozen-lockfile`, `uv sync --frozen`, `pip install --require-hashes` and the phrase
"`npm install X` written into `AGENTS.md`". A blocking rule would refuse the very edit that
closes G4, and this repo's `README.md` would be similarly unwritable.

Implemented as `warn_log`, using the hook's existing warn→block review pattern. Bare and
lockfile forms are ignored — the pattern requires a non-flag argument, i.e. an actual
package name — so `npm ci` and `uv sync --frozen` do not fire. **Promote to block only
after reviewing real warn-log volume**, per plan 02 §8 on false-positive rate. Two tests
assert both directions.

**T06 — Tests.** ✅ **DONE. 61 → 79 passed, 0 failed.** File:
`sandbox_templates/claude/hooks/deny-destructive.test.sh`. Fixtures are real files in a
`mktemp -d`, because rule 13 reads the manifest from disk. 18 new assertions: 5 dep-add
positives (package.json, PEP 508, requirements.txt, MultiEdit, whole-file Write), **4
version-bump merge gates**, 5 further negatives (scripts change, `version`,
`requires-python`, comment, non-manifest file), and 4 for rule 14 in both directions.
Original minimum:

| Case | Expect |
|---|---|
| dep-add to `package.json` | **denied** |
| dep-add to `pyproject.toml` | **denied** |
| **version-bump-only edit** | **passes** ← the case that decides whether this survives |
| `npm install foo` inside `AGENTS.md` | **denied** |
| prose naming a package in `README.md` | **passes** |

Plan 02 §8 is right that false-positive rate is the number that matters. The version-bump
case is the merge gate for T04.

**Also update:** `docs/deny-destructive-hook-plan.md`, `docs/permissions-model.md`.

### Phase 2 — Gate 2 config + `depaudit posture` *(~2–3d)*

**T07 — npm + pip config in the image.** File: `Dockerfile`. Write `/usr/etc/npmrc`:

```ini
min-release-age=7
registry=https://registry.npmjs.org/
save-exact=true
```

Do **not** add `ignore-scripts=true`: npm 12's `allow-scripts` allowlist already covers it,
and setting both risks interacting with `Dockerfile:365`'s
`--allow-scripts=@anthropic-ai/claude-code`.

**T08 — Validate the autoupdater interaction** *(gates T07)*. **[C 07-31]**
`Dockerfile:365` is load-bearing: it is what keeps `claude --version` from reporting
"native binary not installed" (see `claude-settings.json:3`). Run
`scripts/profile.sh <p> build --refresh-ai` and assert `claude --version` afterwards.
**If T07 breaks this, T07 reverts — the working CLI outranks the age gate**, and the
allowlist (§0) is already covering npm resolution in the meantime.

**T09 — Formalise the allowlist lifecycle** *(G8 + phase 2b, now cheap)*. File:
`proxy/allowed_domains.txt` + `.agents/skills/squid-management.md`.

- Fix the stale header (G8) so it describes the deployed posture: registries live in a
  gated tier and are opened only inside a `with-egress.sh` window.
- Name the two states — `locked` (registry tags commented; today's actual state) and `dev`
  (tags uncommented) — and make the selection per-profile rather than a manual edit.
- **Recommended default: `locked`**, because it is the observed status quo (§0). The draft
  recommended `dev`; that recommendation is superseded. **[D1]**
- **[C 07-31]** `with-egress.sh`'s `open_section()` is idempotent on already-open sections,
  so `--with pypi` works unchanged in either state. No change to the window's contract.
- Also record the `@jsr` finding (plan 01 `N05`): **[C 07-31]** `npm.jsr.io` is not in the
  allowlist, so the default `@jsr:registry` scoped registry is already closed by egress.
  Record as a deliberate finding rather than leaving it an accident.

**T10 — pnpm age gate in per-profile state.** File: `scripts/init-profile-state.sh`. Seed
`config/pnpm/rc` with `minimumReleaseAge=10080` (**minutes** — plan 02 §Gate 2 flags the
unit mismatch; 10080 = 7 days), using the existing idempotent idiom at lines 39–40 (D3).

**T11 — uv per-project pattern.** Document `exclude-newer` as per-project in
`docs/local-wheels.md` or a new note. Do **not** set it image-wide (D3).

**T12 — Tier-1 tripwires.** File: `scripts/verify-sandbox.sh`. **[C 07-31]** the script
runs inside the container via `docker exec ... bash -s` and uses `pass`/`fail`/`warn`/`note`
helpers (lines 19–24). Add checks asserting the live values: `npm config get
min-release-age` ≥ 1, pnpm `minimumReleaseAge` set. This is what makes image-layer config
trustworthy despite the agent being root (D3).

**T13 — `depaudit posture`.** File: `scripts/depaudit.py`. Python 3.11+ stdlib, read-only,
no network (D2). Plan 01 phase 1 only — `discover` + the applicable `posture` subset:

| Keep | Drop, with reason |
|---|---|
| `N01`–`N04`, `N06`, `N09`, `N11` | `N05` — reduced to the single `@jsr` case (T09) |
| `P01`–`P06`, `P08` | `N07`/`P07` — no CI in these repos; keep the check, expect `N/A` |
| `X01`, `X04`, `X05`, `X06`, `X07` | `N08`, `N02y`, `N02b` — toolchain absent, emit `N/A` |
| | `X02`; `X03` should assert *our* hook wiring, not a generic one |

`X04` (agent-instruction files as executable surfaces) and `X07` (dependency-add provenance
from `git log -p`) are the two highest-value checks for this estate and the two most
implementations skip. **Do not defer them.**

**T14 — Surface it.** Files: `scripts/profile.sh`, `justfile`. Add
`scripts/profile.sh <profile> deps` — per golden rule 1, discovery goes through
`profile.sh` even though the scanner is a standalone read-only script that spawns nothing.
**[C 07-31]** `profile.sh` has no `deps` subcommand today; the justfile is a thin alias
layer (`verify profile:`, `audit profile *args:` …) and gets a matching pass-through.

**T15 — Fixtures.** Plan 01 §10: an untested scanner is decorative. Ship fixture repos —
full posture, zero posture, multi-lockfile, and **the docs-only injection case** (malicious
name present *only* in `AGENTS.md`) that exercises `X04`. Extend the known-good corpus with
**FastAPI, Strawberry GraphQL and rdflib** alongside `express`/`requests`/`lodash`, because
those three are what the reported May 2026 withdrawal incident wrongly flagged — a
`withdrawn`-handling regression surfaces there first.

**T16 — `depaudit pkg` + OSV cross-check** *(~0.5d, the smallest high-value unit)*. Per D6,
~40 lines of `urllib` on top of T13:

```
purl(s) ──▶ POST /v1/querybatch ──▶ filter ids to ^MAL- ──▶ GET /v1/vulns/{id}
                                         │                        │
                                    else: discard          withdrawn? ──▶ INFO
                                    (GHSA/PYSEC/CVE                │
                                     are non-signals here)         └─▶ BLOCK
```

| Condition | Verdict |
|---|---|
| `MAL-`, `withdrawn == null` | **BLOCK** |
| `MAL-`, `withdrawn` set | INFO — log, do not act; evidence the corpus self-corrected |
| Only `GHSA-`/`PYSEC-`/`CVE-` | **Not a signal here.** Separate section (plan 01 §8) or nothing |
| Network failure / timeout | `UNKNOWN` → ask, **never** `PASS` (plan 01 §1) |

Cache keyed `(purl, date)`, 24h TTL. Cache metadata, never an artifact.
**`depaudit pkg` is the same code path T18's pre-flight calls** — one implementation of "is
this package trustworthy", two invocation contexts, or the scanner and the gate drift and
start disagreeing, which is worse than having only one.

**Ship T16 after T07/T10, not before.** OSV is reactive; a miss means nothing. The age gate
covers the window where intel structurally fails, and it works with no network, no API and
no vendor. Intel is the complement, not the primary. This is the sequencing most likely to
be got wrong, because T16 is the more satisfying thing to build.

### Phase 3 — Instrument the install window *(~2d; no longer blocked)*

**~~T17 — Fix `reload_proxy`~~ — DROPPED.** T01 refuted G1; there is no bug to fix. See §6
G1. `with-egress.sh`'s reload path is left exactly as it is.

**T24 — Allowlist drift tripwire** *(G9, replaces T17)*. File: `scripts/verify-sandbox.sh`
(tier 1). Assert that what the proxy loaded equals what the repo says:

```sh
diff <(grep -vE '^[[:space:]]*#|^[[:space:]]*$' proxy/allowed_domains.txt | sort) \
     <(docker exec -u proxy egress-proxy-$p \
         grep -vE '^[[:space:]]*#|^[[:space:]]*$' /etc/squid/allowed_domains.txt | sort)
```

`fail` on any delta, naming the domains and directing to `docker restart
egress-proxy-<profile>`. Extra-domain deltas are the dangerous direction: a domain the repo
removed but the proxy still permits is an open hole, not a config lag.

**[C 07-31] That file diff alone is NOT sufficient — there are two staleness modes and it
catches only one.** Measured while testing the dashboard reload:

| Mode | Container sees new bytes? | Caught by file diff? | `squid -k reconfigure` | `docker restart` |
|---|---|---|---|---|
| **A — unreloaded edit** (in-place write; inode preserved) | yes | ❌ **no — file matches** | ✅ applies | ✅ applies |
| **B — stale inode** (atomic replace: `vim`, `sed -i`, `git checkout`) | no | ✅ yes | ❌ **silent no-op** | ✅ applies |

Mode A is invisible to a file comparison: the container's copy is byte-identical to the
repo's, but **squid parsed the allowlist into memory at start** and is still enforcing the
old set. Proven directly — with `fonts.gstatic.com` commented out in place, the container's
file showed it commented while `curl https://fonts.gstatic.com/` still returned `404`
(i.e. squid tunnelled it). G9 as originally found was Mode B; Mode A is a second gap.

So T24 needs **both**:

1. **File diff** (above) — hard `fail`. Catches Mode B.
2. **Reload-lag check** — `warn` when `proxy/allowed_domains.txt` mtime is newer than the
   proxy container's `.State.StartedAt` and no reload has happened since. Catches Mode A
   without a network call, which matters because tier-1 `verify` must never depend on
   egress (§10). An egress probe would be definitive but is not tier-1 appropriate.

**[C 07-31]** The file read must use `docker exec -u proxy` for `access.log` (T20): the
container is `cap_drop: ALL` + `cap_add: [SETGID, SETUID]` (`CapEff 0xc0`), so UID 0 has no
`CAP_DAC_OVERRIDE` against the `0640 proxy:proxy` log. The *allowlist* is host-owned `0644`
and readable by root, so `_count_active_domains`-style reads are fine either way.

**T18 — Pre-flight.** Extract package specs from the command; run `depaudit pkg` (T16) per
spec. `BLOCK` refuses to open the window; `REVIEW` prints signals and asks. Plan 02's
2-second hook budget does not apply — this is human-driven, seconds are affordable, so
query serially and skip the concurrency machinery plan 01 §6 specifies for fleet scans.

**T19 — Bracket + snapshot.** Record `date +%s` before opening and after closing. Before:
lockfile hashes, `node_modules/` and `site-packages/` top-level listings. After: the same.

**T20 — Egress diff.** Filter `access.log` (field 1 is epoch seconds) to the bracket;
extract distinct destination hosts, reading via **`docker exec -u proxy`** (see T24 —
root cannot read the log). Timestamp-filtering rather than byte-offsets survives a proxy
restart mid-window. Anything outside `{registry, CDN}` during an install
window is plan 02 §Gate 4's high-signal, low-FP evidence — *observable* here rather than
theoretical, because the window is explicit and narrow.

**T21 — Filesystem diff.** New top-level dirs not accounted for by the lockfile delta —
plan 02 §Gate 4's "files present that no package declares".

**T22 — Persist** *(G7)*. Append one JSON line per window to
`~/.ai-sandbox/profiles/<profile>/audit/depgate.jsonl`. **Host side, not tmpfs** — per the
AGENTS.md state rule, losing it would hurt, so it does not live in a container layer.
`scripts/init-profile-state.sh` creates `audit/`. `profile.sh <p> deps --history` reads it
back.

### Phase 4 — Python script gate, staged *(deferred, data-gated)*

**T23.** `PIP_ONLY_BINARY=:all:` / `--only-binary :all:` *(G6)*. Highest-value remaining
control, highest friction on this image. Gate it behind phase 3 telemetry: run `depaudit`'s
`P08` (sdist detection) across the real profiles and count how many packages actually
resolve to sdists. Small → impose image-wide. Large → impose per-project.
**Do not decide this in advance of the data.**

---

## 8. Validation plan

**T00 — Re-baseline. Run before *each* phase-2 session, not once.** Versions moved
measurably in 24h (§0.1).

```bash
docker run --rm windows-ai-sandbox:latest bash -lc \
  'npm --version; pnpm --version; node --version; uv --version; pip --version;
   npm config get min-release-age; npm config get allow-scripts;
   npm config get globalconfig; pnpm config get minimumReleaseAge'
```
Expect: npm ≥ 11.10.0, pnpm ≥ 10.16, `min-release-age` `null`, `minimumReleaseAge` unset,
`globalconfig` = `/usr/etc/npmrc`.

**Per phase:**

| Phase | Command | Pass condition |
|---|---|---|
| 0 | `scripts/sync-agent-notice.sh` then `git diff` | notice block present in target `AGENTS.md` files; no unintended edits |
| 1 | `bash sandbox_templates/claude/hooks/deny-destructive.test.sh` | **≥ 66 passed, 0 failed** (61 existing + 5 new) |
| 1 | `scripts/profile.sh <p> verify` | no new FAIL |
| 2 | `scripts/profile.sh build --refresh-ai` then `docker run --rm <img> claude --version` | prints a version, **not** "native binary not installed" — this is T08 and it gates T07 |
| 2 | `docker run --rm <img> npm config get min-release-age` | `7` |
| 2 | `docker exec sandbox-<p> pnpm config get minimumReleaseAge` | `10080` |
| 2 | `scripts/profile.sh <p> verify` | new Gate-2 tripwires PASS |
| 2 | `grep -cvE '^\s*#\|^\s*$' proxy/allowed_domains.txt` | 53 before T09; assert the intended count after |
| 2 | `python3 scripts/depaudit.py posture .` | runs offline, exits 0, zero flags on the known-good corpus |
| 2 | `python3 scripts/depaudit.py pkg npm unused-imports` | **BLOCK** (`MAL-2025-48781`) |
| 2 | `python3 scripts/depaudit.py pkg npm express` | no BLOCK — `GHSA-` present but not a signal on this path |
| 2 | T24 allowlist diff, per profile | zero delta between host file and every running proxy |
| 3 | `scripts/with-egress.sh <p> --with pypi -- 'python -c "import sys;print(sys.version)"'` | window opens and closes; one JSONL line appended |
| all | `scripts/profile.sh <p> audit` | tier-2 probes clean |

**G1 reproduction (T01) — RUN 2026-07-31, result: refuted.** Kept for the record, because
the negative result is the finding:

```bash
docker exec egress-proxy-<p> squid -k reconfigure; echo "exec exit=$?"
timeout 6 docker wait egress-proxy-<p>; echo "wait rc=$?"     # no foreground sleep needed
docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' egress-proxy-<p>
```

Observed: `exec exit=0`, `wait rc=124` (never stopped), `running 0`. The plan's own
instruction was to drop T17 in exactly this case, and it has been dropped. **[C 07-31]**

**G9 drift check (T24) — the check that found the live defect:**

```bash
diff <(grep -vE '^[[:space:]]*#|^[[:space:]]*$' proxy/allowed_domains.txt | sort) \
     <(docker exec -u proxy egress-proxy-<p> \
         grep -vE '^[[:space:]]*#|^[[:space:]]*$' /etc/squid/allowed_domains.txt | sort)
```
Expect empty. A `>` line is a domain the proxy permits and the repo does not — the
dangerous direction. Note `-u proxy`; root cannot read the file.

---

## 9. Acceptance criteria

**Phase 0:** the five rules appear in `agent-notice.md`; the sync propagates them; the
notice states that install commands in instruction files require the same verification as
manifest entries.

**Phase 1:** `pnpm add`, `pnpm install`, `pnpm dlx`, `uv sync`, `uv lock`, `yarn add`,
`bun add`, `poetry add` are all denied, not prompted. An Edit adding `"left-pad": "^1.0.0"`
to `package.json` is blocked with an actionable reason. An Edit changing `"1.0.0"` →
`"1.0.1"` **passes**. An Edit adding `npm install foo` to `AGENTS.md` is blocked. The test
harness is green at ≥ 66.

**Phase 2:** `npm config get min-release-age` returns 7 inside a running profile; pnpm
returns 10080; `verify` asserts both and fails if either drifts; `claude --version` still
works after `build --refresh-ai`; `depaudit posture` runs offline against any repo and
emits `PASS/FAIL/N/A/UNKNOWN` with file and line; `depaudit pkg npm unused-imports` returns
BLOCK; the known-good corpus (including FastAPI, Strawberry GraphQL, rdflib) returns zero
flags; the allowlist header describes the deployed posture.

**Phase 3:** opening a window for a BLOCK-tier package refuses; a normal install appends
one JSONL line to the host-side audit log containing the bracket timestamps, the egress
host set, and the lockfile delta; `profile.sh <p> deps --history` reads it back.

**Phase 4:** a decision recorded, with the sdist count that justified it.

---

## 10. Security, reliability, rollback

**Security impact of each phase.** Phases 1 and 2 touch files on the AGENTS.md
security-sensitive list — `claude-settings.json`, the hooks, `Dockerfile`,
`allowed_domains.txt`, `profile.sh`, `init-profile-state.sh`, `verify-sandbox.sh`. Each
commit must state its security impact, `scripts/profile.sh <p> verify` must pass, and
`audit` should be run for anything non-trivial. Hook edits additionally require
`deny-destructive.test.sh` green.

**Every control here is defence-in-depth, not the boundary.** The boundary remains
rootless Docker + cap_drop + seccomp + `internal: true` + the Squid allowlist. Nothing in
this plan should be described as *the* protection; `claude-settings.json:42` already makes
this argument about itself and it applies unchanged.

**Rollback.**

| Phase | Rollback | Blast radius if wrong |
|---|---|---|
| 0 | Revert the notice, re-sync | Prose only |
| 1 | Revert the JSON + hook, re-run tests | Agent friction — false-positive denials. Recoverable in one edit; the human's `zsh` is unaffected |
| 2a (T07) | Revert the Dockerfile line, rebuild | **A broken `claude` binary in the image** — the T08 case. Highest-consequence step in the plan |
| 2b (T09) | Uncomment the tags, restart the proxy | Installs fail with `TCP_DENIED` until reverted |
| 2c (T13) | Delete the script | None — read-only, spawns nothing |
| 3 | Revert `with-egress.sh` | Install window breaks; **`with-egress.sh` is currently the only registry route (§0)**, so this blocks all installs. Test on one profile first |
| T24 | Remove the check | None — read-only assertion; a false positive costs a `verify` FAIL, not a broken profile |
| 4 | Unset the env var | Sdist-only packages fail to build |

**Reliability note.** T12's tripwires must not depend on the network. Per plan 01 §1,
posture checks are local and must work offline; an unreachable OSV must **never** fail an
`up`. `verify` (tier 1) makes no network call.

---

## 11. Risks

| Change | Risk | Mitigation |
|---|---|---|
| `min-release-age=7` | Blocks legitimate same-week releases. Plan 02 §Gate 2: **cannot be scoped per registry**, so private packages are held back too | Start at 7, not 14. `min-release-age-exclude` exists in npm 12 — use it with a mandatory reason comment per plan 02 §2 |
| T07 vs `Dockerfile:365` | **The one that breaks the image.** A broken `claude` is worse than a missing age gate | T08 is a hard gate on T07; revert on failure |
| T04 manifest rule | **False positives are the adoption killer** (plan 02 §8). A version bump must not trip it | The regex targets `"name": "<specifier>"` *introductions*. T06's version-bump case is the merge gate |
| `locked` default | Breaks on-the-fly `uv run` resolution, `container_testing`'s uv project, any `pnpm run build` that installs | Already the deployed state (§0) — so this risk is being *lived with today*, not introduced. Confirm nothing is silently broken before formalising |
| **OSV `MAL-` as a block** | **The one way "it can only help" is false.** A wrongly-published `MAL-` on a popular package wired to `--fail-on block` breaks the build for a legitimate dependency. The reported May 2026 withdrawal of 157 records is the worked example | Honour `withdrawn` (D6); keep T15's extended corpus green; break-glass override, logged. **Never gate tier-1 `verify` on a network call** |
| OSV as *confidence* | Reactive. A clean result means "nothing known yet", not "safe" | Report `NO-KNOWN-MAL`, never `PASS`. The age gate covers the unknown window |
| `save-exact=true` | Changes resolution semantics for new installs | Low — makes lockfile diffs reviewable, which is the point |

**Two things this plan does not deliver**, per plan 02 §9: a patient squatter who waits out
the quarantine, and compromise of an already-trusted dependency. Neither age gates nor
egress containment touch those. The control that does is a human deciding each new
dependency deliberately — which is what phase 0 and T04 exist to force, and why T04 blocks
rather than warns.

---

## 12. Sequencing and task breakdown

No `.beads/` in this repo **[C 07-31]**, so the breakdown lives here — a complete workflow,
not a degraded one (upstream ADR-0003).

| ID | Task | Phase | Effort | Depends on |
|---|---|---|---|---|
| ~~T00~~ | ~~Re-baseline container probe~~ — **DONE 07-31**, §0.1 | — | — | — |
| ~~T01~~ | ~~Reproduce G1~~ — **DONE 07-31, REFUTED**, §6 G1 | — | — | — |
| ~~T02~~ | ~~Rules into `agent-notice.md` + sync~~ — **DONE 07-31** | 0 | — | — |
| ~~T03~~ | ~~Deny-list symmetry~~ — **DONE 07-31**, 74→87 denies | 1 | — | — |
| ~~T04~~ | ~~`manifest-dep-add` hook rule~~ — **DONE 07-31**, rule 13, blocks | 1 | — | — |
| ~~T05~~ | ~~Docs install-command rule~~ — **DONE 07-31**, rule 14, **warns** (deviation, §7) | 1 | — | — |
| ~~T06~~ | ~~Hook tests~~ — **DONE 07-31**, 61→**79 passed, 0 failed** | 1 | — | — |
| ~~T07~~ | ~~`/usr/etc/npmrc`~~ — **DONE 07-31**, +`/etc/pip.conf` | 2 | — | — |
| ~~T08~~ | ~~Validate autoupdater~~ — **DONE 07-31, PASSED** (`claude 2.1.220` after `--refresh-ai`) | 2 | — | — |
| ~~T09~~ | ~~Allowlist lifecycle + header~~ — **DONE 07-31** (D1 = strict) | 2 | — | — |
| ~~T10~~ | ~~pnpm quarantine in state init~~ — **DONE 07-31** (kebab-case fix) | 2 | — | — |
| ~~T11~~ | ~~uv `exclude-newer` documented~~ — **DONE 07-31** | 2 | — | — |
| ~~T12~~ | ~~Tier-1 Gate-2 tripwires~~ — **DONE 07-31**, verify 31→**35 passed** | 2 | — | — |
| ~~T24~~ | ~~Allowlist drift tripwire~~ — **DONE 07-31**, host-side in `profile.sh` | 2 | — | — |
| ~~T13~~ | ~~`depaudit posture`~~ — **DONE 08-02**, `scripts/depaudit.py` | 2 | — | — |
| ~~T14~~ | ~~`profile.sh deps` + justfile~~ — **DONE 08-02** | 2 | — | — |
| T15 | Fixtures + corpora | 2 | 0.5d | T13 |
| ~~T16~~ | ~~`depaudit pkg` + OSV `MAL-`~~ — **DONE 08-02**, + `deps` lockfile mode | 2 | — | — |
| ~~T17~~ | ~~Fix `reload_proxy`~~ — **DROPPED**, G1 refuted | 3 | — | — |
| T18 | Window pre-flight | 3 | 0.5d | T16 |
| T19 | Bracket + snapshot | 3 | 3h | — |
| T20 | Egress diff | 3 | 3h | T19 |
| T21 | Filesystem diff | 3 | 2h | T19 |
| T22 | Persist to host audit log | 3 | 3h | T19–T21 |
| T23 | Python wheels-only, staged | 4 | TBD | T22 telemetry |

**Suggested order.** ~~T00 + T01 first~~ — **both done 2026-07-31**; they removed one task
(T17) and added another (T24). Next: **phase 1 in full** — half a day, closes the
manifest-edit path (the acute unguarded risk), and per plan 02 §7 it produces the telemetry
that sets every other threshold. Phase 0 can land any time. Then T09 + T24 (both cheap, both
fix live defects), then T07/T08/T10/T12, then T13→T16. Phase 3 is no longer gated.

**On sequencing T16:** it is the cheapest unit here and the most tempting to do first,
because a verified-working free API is more satisfying to build than an `.npmrc` line.
Resist. T07/T10 cover the window where every intel feed structurally fails; T16 without
them catches only what someone else already caught.

---

## 13. Open decisions

Four of five block only later phases, so none of them should hold up phases 0–1.

| # | Decision | Recommendation | Blocks | Becomes |
|---|---|---|---|---|
| D1 | `locked` vs `dev` egress default | **`locked`** — it is the observed deployed state (§0); the draft's `dev` recommendation is superseded | T09 | ADR when decided |
| D2 | Quarantine window: flat 7d, or 7/14 split by plan 02's `high_risk_days` | **Flat 7** until there is data to justify the complexity | T07, T10 | plan detail, not an ADR |
| D3 | Does `depaudit` live here or in its own repo? | **Build in `scripts/` here; extract the first time a second repo needs it.** Do not pre-build the abstraction (plan 04 §5) | T13 | ADR when extracted |
| D4 | A second intel source, ever? | **Ship T16, let phase 3's log accumulate a month, decide from the observed `MAL-` hit rate.** If OSV never fires, a second source is not the missing piece — the age gate is doing the work | T16+ | ADR when decided |
| D5 | Cross-port to macolima | Phases 0, 1 and T07 are portable; phase 3 is not (different egress topology). Cross-check `deny-destructive.sh` against the sibling before merging, keep it bash-3.2-safe (D5) | — | per golden rule 3 |

**Already recorded:** the scope refusals of §3 are drafted as
[`docs/adr/0002-dependency-guardrail-scope.md`](../../docs/adr/0002-dependency-guardrail-scope.md)
(Proposed) rather than buried here, per `make-plan` §4 — they affect the security boundary
and would otherwise be re-litigated every time someone reads plan 02.


---

## 14. Phase 2 results (config half) — 2026-07-31

**T07 — image config.** `/usr/etc/npmrc` with `min-release-age=7`,
`registry=`, `save-exact=true`; plus `/etc/pip.conf` pinning the index with no
`extra-index-url`. **Ordering is load-bearing and the plan did not call it out:**
the npmrc layer MUST come after the claude/agy install, because `min-release-age`
applies to `npm install` at *build* time too — written earlier it would make
`@anthropic-ai/claude-code@latest` unresolvable whenever the newest release is
inside the quarantine window, a self-inflicted build break. `/usr/etc` does not
exist in the base image and must be created.

**T08 — the gate on T07: PASSED.** `scripts/profile.sh build --refresh-ai` then
`claude --version` → `2.1.220 (Claude Code)`, not "native binary not installed".
The layer ordering is why. `agy` 1.1.9 also healthy.

**T10 — pnpm, and a bug the tripwire caught.** pnpm documents the setting as
`minimumReleaseAge`, and this plan said the same — but **in the rc file that
spelling is silently ignored** (`pnpm config get minimumReleaseAge` → `undefined`).
It must be written kebab-case as `minimum-release-age=10080`, matching the
existing `manage-package-manager-versions` line. **[C 07-31]** Seeded by both
`init-profile-state.sh` and `profile.sh ensure_state` (they mirror each other).
T12 is what surfaced this — the config looked right and was doing nothing.

**T12 — tripwires, verify 31 → 35 checks.** npm age, pnpm age, `allow-scripts`,
and pip `extra-index-url` absence. The pnpm check fails *distinctly* when the
value is under 1440, because that means days were entered where minutes are
required — a 1440× error that fails OPEN.

**T24 — drift tripwire, host-side.** **The plan put this in
`verify-sandbox.sh`; that is impossible.** That script is streamed into the AGENT
container, which can see neither this repo (not bind-mounted) nor the proxy. It
lives in `profile.sh`'s `verify` subcommand instead, which also meant dropping the
`exec` so the host-side result still affects the exit code. Verified both ways:
clean → `[ OK ] allowlist in sync (53 domains)`; induced Mode B drift → names the
domain and direction, prints the fix, and exits 1.

**T09 — D1 answered: strict.** Header rewritten to state that registries are
commented by default and that opening one is a bounded `with-egress.sh` act.
Closes G8.

**T11 — uv stays per-project.** `exclude-newer` takes a timestamp, not a
duration, so an image-wide value freezes every project at a fixed date and goes
stale. Documented in `docs/local-wheels.md`.

**State:** all three profiles rebuilt, `verify` **35 passed / 0 failed** each.


---

## 15. Units cross-check (2026-08-01)

Prompted by a sibling audit of an app whose `.npmrc` carried
`minimum-release-age=0`. **Both units verified from the implementations, not the docs:**

| Tool | Setting | Unit | Source of truth | Our value |
|---|---|---|---|---|
| npm | `min-release-age` | **DAYS** | `man 7 config`: "versions that were available more than the given number of **days** ago"; npm's own example is `min-release-age=7` | `7` = 7 days |
| pnpm | `minimum-release-age` | **MINUTES** | `pnpm.cjs`: `new Date(Date.now() - minimumReleaseAge * 60 * 1e3)` | `10080` = 7 days |

**The two settings use different units and both of our values are correct and equal.**
Do not "harmonise" them to the same number — that is a 1440× error in one direction or the
other. The sibling app's `1440` is the same unit as our `10080`; it is a 24-hour window
where ours is 7 days, which is a policy difference, not a units bug.

**Value verdict: keep 7 days here.** The friction argument for 24h is real in a normal repo,
but it is weak in this one — the registries are closed by default (§0), so installs already
happen only inside a deliberate `with-egress.sh` window and are rare. This is also the
high-autonomy, agent-driven environment the whole threat model is about. `min-release-age-exclude`
/ `minimumReleaseAgeExclude` exist for the case where a genuinely fresh release is needed.
Revisit if the quarantine actually blocks real work more than about once a month.

**Failure-mode table, verified in-image with node:**

| Value | Cutoff | Effect |
|---|---|---|
| `10080` | 7 days ago | intended |
| `1440` | 24 h ago | valid, shorter window |
| `0` | none (falsy) | quarantine **OFF** |
| `"0s"` / `"7d"` | **Invalid Date** | **rejects EVERY version** — nothing resolves |

The suffixed forms are the trap: they look like a duration, parse as `NaN`, and fail closed
in a way that reads as a broken registry rather than a config error. T12 now hard-`fail`s on
any non-integer for exactly this reason, and its message states the fix.


---

## 16. T13 result (2026-08-02)

`scripts/depaudit.py` — Python 3.11+ stdlib only, read-only, offline. 21 checks
across discover / Node / Python / cross-cutting, each emitting
`PASS|FAIL|WARN|N/A|UNKNOWN` with the file and line that produced it. Markdown and
JSON output (`schema: depaudit/posture/1`), `--fail-on {fail,warn,never}`.
Verified: no network code, zero write calls, one read-only `git` subprocess for
X07 provenance.

**A false positive it caught in itself, worth recording.** The first draft of
`N02p` hard-FAILed `minimum-release-age` when set in `.npmrc`, generalising from
the `supportedArchitectures` finding of the day before. That generalisation was
wrong. Measured with a deliberately absurd 10-year window: the install failed
from `.npmrc` **and** from `pnpm-workspace.yaml`, so **both locations are
enforced** for this setting. The difference is scalar vs nested-object settings —
a plain `key=value` survives the npmrc path, a nested map does not. The check now
accepts either location and flags only absent / zero / non-integer / sub-day
values. Per plan 02 §8, a false FAIL is worse than no check: it trains people to
ignore the output.

**Real findings on first run**, none of them planted:

- `app_blast` — install commands in `AGENTS.md` and `docs/handoff/README.md`
  (X04, the check most implementations skip); two manifest commits with no
  matching lockfile change (X07).
- `dashboard` — **45 dependencies resolve to sdists** (P08), i.e. 45 packages
  running `setup.py` at install time. That is exactly the data T23 (phase 4,
  Python wheels-only) was deferred pending, and it says image-wide
  `--only-binary :all:` is not viable here.
- Root of this repo — no manifests at root but nested projects exist (D03), so
  the scan says so instead of reporting a misleading clean.

**Scope honestly stated:** root-scoped, one directory per run. Monorepo recursion
is not implemented; D03 exists so that limitation is visible rather than silent.


---

## 17. T16 result (2026-08-02)

`depaudit pkg <eco> <name> [version]` and `depaudit deps <path>`, sharing one OSV
client — the same code path phase 3's install-window pre-flight will call, per
plan 01 §9. Host-side: `api.osv.dev` is deliberately NOT in the allowlist, so the
cross-check adds no egress surface to any profile.

**`MAL-` only.** `GHSA-`/`PYSEC-`/`CVE-` are a different question (this version
has a vulnerability) from the one this gate asks (this package is malicious).
Mixing them turns a supply-chain gate into a CVE treadmill nobody reads.

**Corpus, verified live:** `unused-imports` → **BLOCK** (`MAL-2025-48781`, exit 1).
Known-good `express@4.18.0`, `requests@2.31.0`, `lodash`, and the three wrongly
flagged in the reported May 2026 withdrawal — `fastapi`, `rdflib`,
`strawberry-graphql` — all `NO-KNOWN-MAL`. `--offline` yields `UNKNOWN`, never a
pass. Cache keyed `(purl, UTC date)`: 748 packages take 3.7s cold, 0.08s warm.

**Correction to D6:** the plan recorded `withdrawn: null` on a live `MAL-` record.
The field is **absent**, not null. `.get()` returns `None` either way so the logic
is unchanged, but the claim was wrong.

**A bug the validation caught, and the reason to keep validating.** The first
lockfile parser split `name@version` on the LAST `@`. pnpm v9 keys carry a
peer-dependency suffix — `@anthropic-ai/sdk@0.104.1(zod@4.4.3)` — whose own `@`
won that split, producing the garbage name `@anthropic-ai/sdk@0.104.1(zod`.
**121 of 869 entries were affected, and a name OSV cannot match returns no
records, so every one of them reported clean.** A false all-clear, silently, on
14% of the tree. Fixed by stripping the parenthesised suffix before splitting.

Post-fix the parser independently reproduces the sibling audit's own figures for
`app_blast` — **748 versioned entries, 695 distinct packages**, matching its §1
table exactly. That agreement, derived from a different tool on a different OS, is
the strongest evidence the enumeration is right.

**Cross-platform question this settles:** the lockfile records every optional
platform variant regardless of `supportedArchitectures`, so one `depaudit deps`
run on any machine covers what every other machine would install. There is no
per-device scanning to do.


---

## 18. T14 result (2026-08-02)

`scripts/profile.sh <profile> deps [--osv] [--json] [--strict|--quiet]`, plus a
`just deps <profile>` alias. Routed through `profile.sh` per golden rule 1 even
though `depaudit` is a standalone read-only script — discovery of what a profile
can do belongs there, not in a script the user has to already know about.

**It iterates the workspace, and that turned out to be the whole point.** A
profile's workspace holds MANY repos (`docker-compose.yml`: "the profile's repo
parent folder = /workspace"), and `depaudit` is root-scoped. `therapod` has
**nine** projects under it. Scanning only the root would have reported "no
manifests" and read as clean. `deps` scans the root plus each child carrying a
manifest, then prints a roll-up — nine reports with no summary is how a FAIL gets
scrolled past.

**Real finding on first run: `app_zero` FAILs `N01`** — it has no `allowBuilds` /
`onlyBuiltDependencies` allowlist, so **every** package there may run install
scripts. `app_blast` and `engine` both have one. This is the control the sibling
audit's §6 calls "doing more for you than every CVE bump in §5 combined", and one
of the three repos is missing it. Not fixed here: choosing the allowlist requires
knowing which packages legitimately build, and getting it wrong breaks installs.

`--osv` across the whole workspace covered **1,974 lockfile-pinned packages** in
nine projects, all `NO-KNOWN-MAL`. Host-side, so no profile egress is involved.

Phase 2 is complete apart from T15 (fixtures), which would let the corpus test
run without network as a regression test rather than a live check.
