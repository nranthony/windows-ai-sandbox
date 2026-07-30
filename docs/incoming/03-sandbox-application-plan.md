# Dependency Guardrails — Application Plan for windows-ai-sandbox

**Inputs:** `01-posture-scanner-plan.md` (`depaudit`), `02-layered-gates-plan.md`
(`depgate`), `DEPENDENCY_GUARDRAILS.md`.
**Status:** Plan. Nothing implemented.
**Scope:** what to build *here*, in this repo, against this egress model. The
cross-repo / pre-deployment subset is split out into
[`04-portable-guardrails-outside-sandbox.md`](04-portable-guardrails-outside-sandbox.md).

---

## 0. TL;DR

The incoming plans were written for an org with a fleet of repos and no
containment. This repo is the opposite: one developer, a handful of profiles, and
an egress model that is already **stronger than the "Topology A" those plans
describe as the aspirational end state**. `internal: true` + DNS sinkhole +
Squid allowlist means a slopsquat `postinstall` in this sandbox has no route to
an attacker-controlled host. That is Gate 4 — the gate plan 02 calls the hardest
to get — already paid for.

So the work here is **not** to build `depgate` as specified. It is to:

1. **Close three cheap holes** in the gates we already have (Gate 0 asymmetry,
   manifest-edit path, docs-write path).
2. **Turn on Gate 2**, which is available in every installed tool and configured
   in none of them — a config file, not a program.
3. **Instrument the install window**, which this repo uniquely has as a named,
   bounded, scripted event (`with-egress.sh`). Nowhere else in the incoming
   plans is that primitive available; here it is the highest-leverage hook point
   in the system.
4. **Build `depaudit posture` only** (plan 01 phase 1), stdlib-only, host-side.

And explicitly **not** build: Verdaccio/devpi, the Gate-1 policy HTTP service,
SARIF output, or fleet mode. §4 gives the reasoning so the decision is on record
rather than re-litigated later.

---

## 1. Where the sandbox already sits against plan 02's five gates

Verified against `windows-ai-sandbox:latest` on 2026-07-30 (`docker run --rm`
probes; npm 12.0.1 / pnpm 10.34.5 / node 24.18.0 / uv 0.11.29 / pip 24.0
system-Python 3.12.3).

| Gate | Plan 02 mechanism | State here | Evidence |
|---|---|---|---|
| **0 — Intent** | `PreToolUse` hook checks the name | ⚠️ **Partial, but harder in kind** — `claude-settings.json` *flat-denies* `npm install/ci`, `npx`, `pip install`, `python -m pip`, `uv add/pip install/tool install`, `uvx`, `pipx`, `cargo install`, `go install/get` | `sandbox_templates/claude/claude-settings.json` deny list |
| **1 — Pre-resolution** | Metadata service, `POST /check` | ❌ **Absent** | no equivalent |
| **2 — Resolution** | Age gate + pinned registry | ❌ **Absent in config, present in tooling** — `min-release-age = null`, pnpm `minimumReleaseAge` undefined, no `exclude-newer`. Registry is *de facto* pinned by the Squid allowlist, not by config | `npm config ls -l`; `pnpm config get minimumReleaseAge` |
| **3 — Download, pre-exec** | Script blocking, integrity, tarball inspection | ✅ **npm done by default** (`allow-scripts = [""]`, `dangerously-allow-all-scripts = false`) — this *is* the mechanism the Dockerfile comment describes breaking Claude's autoupdater. ❌ **Python side open** — no `--only-binary :all:`, sdists run `setup.py` freely. ❌ no tarball inspection | `npm config ls -l`; no `pip.conf` anywhere in repo or image |
| **4 — Post-install detection** | Egress deny-by-default during installs | ✅ **Structurally solved, operationally unused** — `internal: true` + `dns: [127.0.0.1]` + allowlist means non-allowlisted egress is impossible, not merely alerted on. But `access_log` is on tmpfs, nothing reads it, nothing retains it | `docker-compose.yml`, `proxy/squid.conf` |

**Read this table as: the expensive gate is done, the cheap gate is missing.**

### 1.1 What the egress model buys that plan 02 only aspires to

Plan 02 §Gate 4 argues that a dependency install has "an extremely narrow
legitimate network profile" and that anything else during an install window is
high-signal evidence. In a normal environment that is a *detection* claim. Here
it is a *prevention* claim, because there is no route out except Squid, and no
DNS to exfil through either. A `postinstall` that phones home to
`evil-cdn.example` gets `TCP_DENIED` and dies.

### 1.2 What it does not buy

Containment is not zero-blast-radius. Three honest caveats:

- **The allowlist contains write-capable, credential-reachable hosts.**
  `github.com` / `api.github.com` are open and `/root/.config/gh` holds a token.
  `storage.googleapis.com` is on the list for Kaggle and is broad. A payload
  that reads the `gh` token and pushes a gist stays entirely inside the
  allowlist. `deny-destructive.sh` rule 9 (`cred-read`) blocks the *agent* from
  touching `/root/.config/gh` — it does not constrain a `postinstall` script,
  which runs outside the Claude tool boundary entirely.
- **The proxy sees CONNECT, not payloads.** `registry.npmjs.org` being
  allowlisted means *any* npm package can be fetched. The allowlist gates hosts;
  it cannot gate package names. That is precisely the gap Gate 2 fills.
- **The interactive shell is ungated.** `claude-settings.json` restricts Claude
  Code's Bash tool only. A human (or a second agent) in `zsh` installs whatever
  they like. This is deliberate and documented — but it means every control that
  lives in the deny list is a control the install window does not have.

---

## 2. The real gaps, ranked

### G1 — `with-egress.sh` reloads Squid with a signal that kills it *(P0, prerequisite)*

`scripts/with-egress.sh:97` runs `docker exec egress-proxy-$profile squid -k
reconfigure`. Commit `3809791` ("fix(dashboard): reload proxies via restart, not
SIGHUP reconfigure") establishes that squid runs as the proxy container's
foreground PID and takes SIGHUP as Hangup, exiting 129 — the reload kills the
container it targets. The fallback at `:100` cannot fire, because `docker exec`
returns 0: the *signal* was delivered successfully, it is the *daemon* that dies.

The inode half of that bug does **not** apply here — `open_section` uses
`cat tmp > $ALLOWLIST` and `cleanup` uses `cp backup $ALLOWLIST`, both of which
write in place and preserve the inode the running proxy is pinned to. Only the
SIGHUP half applies.

Fix: replace `reload_proxy` with the container-restart path the dashboard now
uses, plus the same post-restart liveness + domain-count assertion. **This is a
prerequisite for everything in §5 phase 3**, because the install window is the
thing being instrumented and it currently detonates the proxy on entry.

> Needs a live confirm against one profile before the fix is written — the
> dashboard commit verified the pattern in the dashboard's call path, not in
> `with-egress.sh`'s. Do not assume; reproduce.

### G2 — Gate 0 is asymmetric across package managers

Denied: `npm install`, `npm ci`, `npx`, `pip install`, `pip3 install`,
`python -m pip`, `uv add`, `uv pip install`, `uv tool install`, `uvx`, `pipx`,
`cargo install`, `go install`, `go get`.

Not mentioned at all — so they fall through to `defaultMode: auto`, i.e. a
**prompt**, not a deny:

| Command | Available in image? |
|---|---|
| `pnpm add`, `pnpm install`, `pnpm dlx` | ✅ pnpm 10.34.5 is installed |
| `uv sync`, `uv lock` | ✅ resolves and installs from `pyproject.toml` |
| `poetry add`, `yarn add`, `bun add` | ❌ not installed — cover anyway, cheap |

A prompt is not nothing, but `DEPENDENCY_GUARDRAILS.md` §2.4 names exactly this
failure: approval under task pressure, on a diff the human skims. `pnpm add` is
the sharpest edge — pnpm is installed, and `Bash(pnpm run:*)` is already on the
*allow* list.

### G3 — Manifest edits bypass every install matcher

Plan 02 §Gate 0 calls this out and it is the single most under-covered path here.
`deny-destructive.sh`'s `Edit|Write|MultiEdit` branch guards exactly three path
families (`/usr/local/lib/claude-hooks/`, `/root/.claude/settings.json`,
`/etc/claude/`) and passes everything else. An agent that writes a new line into
`package.json` or `pyproject.toml` and then runs an already-allowed `uv run` or
`pnpm run build` has installed a package without ever issuing an install command.

### G4 — Docs are an executable surface and are unguarded

`DEPENDENCY_GUARDRAILS.md` §2.5 and plan 01 `X04`. This repo is *unusually*
exposed to it: `scripts/sync-agent-notice.sh` **propagates a managed block from
`sandbox_templates/common/agent-notice.md` into repo `AGENTS.md` files and the
global `CLAUDE.md`.** An unverified install command written into that template
gets distributed to every repo the notice syncs into. That is a fan-out path the
incoming plans do not contemplate.

### G5 — Gate 2 is available everywhere and configured nowhere

| Tool | Setting | Version present | Min required (per plan 02) | Configured? |
|---|---|---|---|---|
| npm | `min-release-age` (days) | **12.0.1** | 11.10.0 | ❌ `null` |
| pnpm | `minimumReleaseAge` (minutes) | **10.34.5** | 10.16 | ❌ undefined |
| uv | `exclude-newer` (timestamp) | **0.11.29** | — | ❌ unset |
| pip | none native | 24.0 | — | N/A — proxy-only, and our proxy can't see names |

Every version bar is cleared. This is a config file.

Config-level gates have a property the deny list structurally cannot have:
**they are invocation-path independent.** `claude-settings.json` already
concedes this in its own comment — denies "can be routed around by wrapper
commands (env, xargs, find -exec, make targets, language interpreters)" — and
`Bash(make:*)`, `Bash(just:*)`, `Bash(npm run:*)`, `Bash(pnpm run:*)`,
`Bash(uv run:*)` are all on the *allow* list. An `.npmrc` gate fires no matter
which of those reached the installer, and fires for the human in `zsh` too.

### G6 — Python has no script gate at all

npm 12 blocks lifecycle scripts by default; Python does not. Any sdist that
resolves runs `setup.py` at build time. Plan 02 §Gate 3 notes wheels-only is a
*stronger* guarantee than `ignore-scripts` — but it is also the highest-friction
control to impose on a CUDA/ML image, which is what this is. See §6.

### G7 — The proxy audit trail is tmpfs and unread

`squid.conf:40` writes `access.log` to a tmpfs mount, explicitly "intended for
in-session forensics, not long-term storage." Nothing tails it, nothing retains
it, nothing correlates it with install activity. The single most valuable signal
this architecture produces is being discarded on every proxy recreate.

---

## 3. Design decisions specific to this repo

**D1 — One implementation, two invocation contexts (plan 01 §9) still holds, but
the contexts are different here.** Not "scanner + hook"; rather **"scanner
(host, networked) + install-window pre-flight (host, networked)"**. Nothing runs
inside the agent container, because the agent container cannot reach a registry
API except through Squid and only when a section is open. Keep `depaudit`
host-side.

**D2 — stdlib-only is not a preference here, it is house style.** Plan 01 §1
argues a supply-chain tool must not have a supply chain. This repo already
enforces that pattern: `sandbox_templates/bin/webfetch` is stdlib-`urllib` for
the same reason. `depaudit` follows it. No exceptions, no "just this one
dependency."

**D3 — Where config lives determines whether it survives.** Per AGENTS.md's
container-state table:

| Config | Path | Persistence | Verdict |
|---|---|---|---|
| npm global | `/usr/etc/npmrc` (`prefix=/usr`) | image layer | ✅ rebuilt from Dockerfile, agent-resettable only by rebuild |
| npm user | `/root/.npmrc` | **writable layer** | ❌ lost on `docker rm`, per-container drift |
| pnpm global | `/root/.config/pnpm/rc` | **bind-mounted, per-profile** | ✅ persists, host-editable, already an ARCHITECTURE.md documented path |
| pip | `/etc/pip.conf` | image layer | ✅ |
| uv | `pyproject.toml` per project | workspace, in git | ✅ correct home for `exclude-newer` |

So: **npm and pip config go in the image** (Dockerfile, rebuilt, tripwire-checked
at runtime); **pnpm config goes in per-profile state** (`init-profile-state.sh`,
same treatment as `git/config`); **uv `exclude-newer` stays per-project** — an
image-wide resolution freeze on an ML sandbox is a footgun, not a control.

The agent is root and can edit `/usr/etc/npmrc`. That is fine — this is
defence-in-depth, exactly as `deny-destructive.sh`'s header already argues about
itself. The answer is the same one this repo already uses: a **tier-1 tripwire**
that asserts the live values on every `up`, so drift surfaces within one cycle.

**D4 — The install window is the design centre.** `with-egress.sh` is a named,
locked, bounded, sentinel-tracked event that opens egress, runs one command, and
closes egress. Plan 02 spends a page arguing for "egress deny-by-default during
install windows" as an aspiration. We *have* the window. Everything in §5 phase 3
hangs off it.

**D5 — Sibling-repo portability constrains the shell.** Per AGENTS.md golden
rule 3 and `docs/sibling-repo-relationship.md`, `deny-destructive.sh` is a
macolima port and is `#!/bin/sh`. Any new rules must stay POSIX sh and
bash-3.2-safe so they cross-port. No `[[`, no arrays, no `${var,,}`.

**D6 — Threat-intel cross-check: OSV only, `MAL-` only, host-side.**

Plan 01 §6 names OSV, deps.dev, and the registry APIs as `enrich` sources;
plan 01 §7 separately lists CVE output (`npm audit` / `pip-audit`) as an
**explicit non-signal** that generates noise and false confidence. Those two
statements are in tension until you look at what OSV actually returns —
verified live 2026-07-30 against `POST https://api.osv.dev/v1/querybatch`,
unauthenticated, no key:

| Query | Response |
|---|---|
| `pkg:npm/express@4.18.0` | `GHSA-qw6h-vgh9-j6wx`, `GHSA-rv95-896h-c2vc` |
| `pkg:pypi/requests@2.31.0` | 3× `GHSA-`, 3× `PYSEC-` |
| `pkg:npm/unused-imports@1.0.0` | **`MAL-2025-48781`** — *"Malicious code in unused-imports (npm)"* |

`unused-imports` is plan 01 §10's known-bad corpus entry; `express` and
`requests` are its known-good corpus. **The `MAL-` ID prefix is exactly the
filter that separates the BLOCK-tier signal from the noise.** Consume `MAL-`
records; discard `GHSA-`/`PYSEC-`/`CVE-` from this code path entirely — they
belong in the separate, clearly-labelled section plan 01 §8 reserves for them.
This resolves the tension and is what makes the cross-check additive rather
than a new false-positive source.

Four implementation facts, all verified, that the design depends on:

- **Name-only queries are accepted** — `{"package":{"name":"unused-imports",
  "ecosystem":"npm"}}` returns the same `MAL-` hit as the versioned purl. So the
  check is usable *pre-resolution*, where there is a name but no version yet.
  Use purls when a version is known, the name form when it isn't.
- **`querybatch` returns only `{id, modified}`** — no `withdrawn` field. Getting
  it requires a second hop, `GET /v1/vulns/{id}`, which does carry
  `withdrawn` (verified `null` on the live `MAL-2025-48781` record, alongside
  `published` and `summary`). Two-step shape: batch → filter to `MAL-` →
  hydrate only the hits. Hits are rare, so the second hop costs ~nothing.
- **`withdrawn` must be honoured.** The thread reports that in May 2026 OSV
  withdrew 157 malicious-package records after automated detection wrongly
  flagged FastAPI, Strawberry GraphQL, and rdflib, propagating bad records into
  downstream CI gates. **Treat that incident as unverified** — but the design
  response holds regardless, and the `withdrawn` field exists to act on. Never
  hard-fail a single `MAL-` hit on a widely-used package; see §6.
- **Host-side means zero egress cost.** `api.osv.dev` is **not** in
  `allowed_domains.txt`. Per D1, `depaudit` runs host-side where egress is
  unrestricted, so **no allowlist change is needed** — the cross-check adds no
  new exfil surface to any profile. That is a real property worth preserving:
  if this ever moves inside the container, it stops being free.

Normalize on **purl** (`pkg:npm/name@version`) as `depaudit`'s internal package
identifier. OSV takes it directly; deps.dev and the GitHub Advisory API map
cleanly; it costs one small formatting function and avoids a per-source
identifier translation layer later.

**Secondary source, also free:** the GitHub Advisory REST API
(`GET /advisories?type=malware&ecosystem=npm`) publishes directly from the npm
security team and often leads OSV, which ingests it. `api.github.com` is
**already allowlisted**, so this too costs no new egress surface. The trap
worth recording: **responses exclude malware unless `type=malware` is passed
explicitly.** Defer to phase 4+ — it is a latency optimisation on a source we
already get via OSV, not a new capability.

---

## 4. What we deliberately do not build

Recorded so it is a decision, not an omission.

| Not building | Why |
|---|---|
| **Verdaccio + devpi in the egress container** (plan 02 §4) | Two new Node/Python services *with their own dependency trees* placed inside the security boundary, to guard against dependency compromise. Plan 02 §4 concedes the bootstrapping problem and offers only partial mitigations. It also contradicts `sandbox-hardening-package.md` §7's minimalism (bubblewrap/socat/openssh deliberately absent). The value it uniquely adds — a pip age gate and artifact inspection — is real; see the re-open condition below. |
| **Gate 1 as an HTTP policy service** | One developer, three profiles. The service exists in plan 02 to stop N call sites drifting. We will have two, both in the same script. A shared function is the correct shape. |
| **SARIF output** (plan 01 §8) | No GitHub code-scanning ingestion in this repo's workflow. Add if that changes. |
| **Fleet mode** (plan 01 §8) | The "fleet" is `~/repo/<profile>/`. `depaudit posture` over a glob is the whole feature. |
| **`policy.yaml` as a versioned artifact in its own repo** (plan 02 §2) | Correct at org scale, overhead at this scale. Keep a single `depaudit/policy.toml` in-repo (TOML, so `tomllib` reads it — no YAML parser, per D2). Revisit if macolima needs to share it. |
| **Socket Firewall (`sfw`)** — install-time proxy for npm/yarn/pnpm/pip/uv/cargo | The argument for it is real: *the exposure is the 200 transitive dependencies, not the package you chose.* But we already answer that twice — plan 01 §5 `inventory` resolves the **full tree including transitives** from lockfiles, and `enrich` runs over every unique `(eco, name)`, not just direct deps. Phase 3 closes the remaining timing gap by diffing the lockfile *inside* the install window. Adopting `sfw` would put a third-party binary that proxies every install **inside** the security boundary, requiring egress to a vendor service — the exact shape D2 exists to refuse. Correct answer for a host with no window; see [`04`](04-portable-guardrails-outside-sandbox.md) §6. |
| **Socket `batchPackageFetch`** (behavioural analysis, ~1k scans/month free) | Genuinely catches what OSV cannot — compromises before an advisory exists. But it costs a new allowlist entry, an API key in `secrets.env`, and a vendor dependency in the trust path. Revisit once OSV's hit rate is known from phase 3 telemetry; do not add a second source before the first has been observed. |
| **`osv-scanner` binary** | A Go binary to avoid writing a `urllib` POST. D2 says no. The API is one stdlib call — verified working in §3 D6. |
| **Local OSV mirror** (`gs://osv-vulnerabilities`) | Would make the check work inside the container offline, and `storage.googleapis.com` happens to be allowlisted already (for Kaggle). But it is ~240k advisory records to sync and keep fresh, against a check that runs host-side where the live API is free. Revisit only if the check moves in-container. |

**Re-open the registry-proxy decision if** any of these become true: pip/uv
usage grows enough that the missing Python age gate is the dominant risk; a
second person gets access; or artifact-level inspection (not just name-level)
becomes a requirement. Until then §5 phase 2's cheaper substitute covers most of
it.

---

## 5. Implementation plan

Five phases. Phases 0–2 are each independently shippable and independently
valuable; do not sequence them behind the later ones.

### Phase 0 — Behavioural rules, zero infrastructure *(~1 hour)*

Take `DEPENDENCY_GUARDRAILS.md` §2 and inline a condensed form into
`sandbox_templates/common/agent-notice.md`, so `scripts/sync-agent-notice.sh`
distributes it to every repo's `AGENTS.md` and the global `CLAUDE.md`. That
script is already this estate's answer to plan 02 §5's "distribution and drift"
problem — use it.

Rules to include, compressed to five lines. Plan 02 is explicit that
instructions are advisory and must not be counted as a control; they earn their
place by improving first-attempt behaviour and reducing how often the real gates
fire.

Guard against G4 in the same pass: the notice must state that install commands
in agent-instruction files are subject to the same verification as manifest
entries — since this file is itself the fan-out vector.

**Deliverables:** edit `sandbox_templates/common/agent-notice.md`; re-run
`scripts/sync-agent-notice.sh`.

### Phase 1 — Close the Gate 0 holes *(~half a day)*

**1a. Symmetry in `claude-settings.json`** *(G2)* — add to `deny`:

```
Bash(pnpm add:*)      Bash(pnpm install:*)   Bash(pnpm dlx:*)
Bash(yarn add:*)      Bash(bun add:*)        Bash(bun install:*)
Bash(poetry add:*)    Bash(uv sync:*)        Bash(uv lock:*)
```

`uv sync` / `uv lock` are the debatable pair — they are *reproduce-the-lockfile*
operations, which §2.3 of `DEPENDENCY_GUARDRAILS.md` explicitly endorses as the
safe form. Deny anyway: `uv sync` will happily resolve a `pyproject.toml` the
agent just edited (G3), which makes it an install command wearing a lockfile
costume. Once Gate 2 is on (phase 2), reconsider allowing `uv sync --frozen`
specifically.

**1b. Manifest rule in `deny-destructive.sh`** *(G3)* — extend the
`Edit|Write|MultiEdit` branch. Not a blanket block on manifest edits (too
noisy — version bumps, script changes, and metadata edits are routine), but a
targeted `manifest-dep-add` rule: block when the target basename is a manifest
**and** the payload introduces a dependency line.

```sh
# after the existing hook-tamper cases, before emit_pass
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

The `emit_block` reason is written *for a model to act on*, per plan 02 §Gate 0:
it states the rule, why, and what to do instead — not just "denied."

**1c. Docs rule** *(G4)* — same branch, for `AGENTS.md`, `CLAUDE.md`,
`agent-notice.md`, `*.mdc`, `.cursorrules`, `README.md`, `SKILL.md`: block when
the payload contains an install command form
(`npm i(nstall)`, `pnpm add`, `pip install`, `uv add`, `uvx`, `npx`).

**1d. Tests** — extend `deny-destructive.test.sh`. Minimum: dep-add to
`package.json` denied; dep-add to `pyproject.toml` denied; version-bump-only edit
**passes** (the false-positive case that decides whether this survives — plan 02
§8 is right that FP rate is the number that matters); `npm install foo` inside
`AGENTS.md` denied; prose mentioning a package name in `README.md` passes. The
harness currently asserts 61/61; AGENTS.md requires it green on every hook edit.

**Deliverables:** `sandbox_templates/claude/claude-settings.json`,
`sandbox_templates/claude/hooks/deny-destructive.sh`,
`sandbox_templates/claude/hooks/deny-destructive.test.sh`,
`docs/deny-destructive-hook-plan.md`, `docs/permissions-model.md`.

### Phase 2 — Turn on Gate 2 + `depaudit posture` *(~2–3 days)*

**2a. Config, per D3.**

- **Dockerfile** — write `/usr/etc/npmrc`:
  ```ini
  min-release-age=7
  registry=https://registry.npmjs.org/
  save-exact=true
  ```
  Do **not** add `ignore-scripts=true`: npm 12's `allow-scripts` allowlist
  already covers it, and setting both risks interacting with the
  `--allow-scripts=@anthropic-ai/claude-code` build step that
  `scripts/profile.sh build --refresh-ai` depends on. Verify that step still
  passes before merging — it is the load-bearing one per the
  "native binary not installed" note.
- **`init-profile-state.sh`** — seed `config/pnpm/rc` with
  `minimumReleaseAge=10080` (**minutes** — plan 02 §Gate 2 flags the unit
  mismatch; 10080 = 7 days). Idempotent, same treatment as `git/config`. Also
  audit the default `@jsr:registry=https://npm.jsr.io/` scoped registry
  (plan 01 `N05`): `npm.jsr.io` is **not** in `allowed_domains.txt`, so it is
  already closed by egress — record that as a deliberate finding rather than
  leaving it as an accident.
- **`pyproject.toml`** — document `exclude-newer` as the per-project pattern in
  `docs/local-wheels.md` or a new note. Do not set it image-wide.
- **`verify-sandbox.sh`** — new tier-1 checks asserting the live values inside
  the container (`npm config get min-release-age` ≥ 1, pnpm `minimumReleaseAge`
  set). Follows the existing "assert the load-bearing line" pattern used for
  `squid.conf`. This is what makes the image-layer config trustworthy despite
  the agent being root.

**2b. A cheaper substitute for the registry proxy** *(this is the one that
replaces Verdaccio)*. `allowed_domains.txt`'s own header already documents the
posture: *"Comment a block out only for fully autonomous agent runs that should
not be able to install or fetch anything."* Make that a first-class,
per-profile setting rather than a manual edit:

- Move `[npm]`, `[pypi]`, `[pytorch]` from PROJECT-PERSISTENT to a
  per-profile-selectable state — `locked` (registries closed; opened only
  inside a `with-egress.sh` window) vs `dev` (today's behaviour).
- Default **`dev`** to avoid breaking the running profiles; opt a profile into
  `locked` and live on it before changing the default.

In `locked` mode, resolution is not merely policy-gated, it is **impossible**
outside an audited window — which is the exact property plan 02 §4 spends a
registry proxy to buy. It does not gate *names* (the proxy would), but it gates
*when*, and it costs one allowlist toggle instead of two services inside the
boundary.

**2c. `depaudit posture`** — plan 01 phase 1 only. `scripts/depaudit.py`,
Python 3.11+ stdlib, read-only, no network. Implements `discover` +
the subset of `posture` checks that apply here:

| Keep | Drop, with reason |
|---|---|
| `N01`–`N04`, `N06`, `N09`, `N11` | `N05` — reduced to the single `@jsr` case above |
| `P01`–`P06`, `P08` | `N07`/`P07` (strict CI install) — no CI in these repos yet; keep the check, expect `N/A` |
| `X01`, `X04`, `X05`, `X06`, `X07` | `N08` (Yarn), `N02y`/`N02b` — toolchain absent, emit `N/A` per plan 01 §3 |
| | `X02`, `X03` — partially covered; `X03` should assert *our* hook wiring, not a generic one |

`X04` (agent-instruction files are executable surfaces) and `X07` (dependency-add
provenance from `git log -p`) are the two highest-value checks for this estate
and the two most implementations skip. Do not defer them to a later phase.

Surface it as `scripts/profile.sh <profile> deps` — per golden rule 1, discovery
goes through `profile.sh` even though the scanner itself is a standalone
read-only script that spawns nothing. Add a `justfile` pass-through.

**2d. Fixtures** — plan 01 §10 is right that an untested scanner is decorative.
Ship `docs/incoming/`-adjacent fixture repos: full posture, zero posture,
multi-lockfile, and **the docs-only injection case** (malicious name present
*only* in `AGENTS.md`) that exercises `X04`.

Extend the corpora for the OSV path (2e): the known-good set must include
**FastAPI, Strawberry GraphQL, and rdflib** alongside plan 01 §10's `express` /
`requests` / `lodash`, because those three are the packages the reported May
2026 withdrawal incident wrongly flagged. If a `withdrawn`-handling regression
ever ships, that is where it surfaces.

**2e. `depaudit pkg` + OSV cross-check** *(~half a day — the smallest
high-value unit in this plan)*.

Per D6. Roughly 40 lines of `urllib` on top of the posture scanner:

```
purl(s) ──▶ POST /v1/querybatch ──▶ filter ids to ^MAL- ──▶ GET /v1/vulns/{id}
                                         │                        │
                                    else: discard          withdrawn? ──▶ INFO
                                    (GHSA/PYSEC/CVE                │
                                     are non-signals               └─▶ BLOCK
                                     here — plan 01 §7)
```

Verdicts, deliberately narrower than a naive "MAL- means block":

| Condition | Verdict |
|---|---|
| `MAL-` record, `withdrawn == null` | **BLOCK** |
| `MAL-` record, `withdrawn` set | INFO — log it, do not act; a withdrawn record is evidence the corpus self-corrected |
| Only `GHSA-`/`PYSEC-`/`CVE-` | **Not a signal on this path.** Report in the separate CVE section (plan 01 §8) or not at all |
| Network failure / timeout | `UNKNOWN` → `ask`, never `PASS` (plan 01 §1) |

Cache keyed `(purl, date)`, 24h TTL, per plan 01 §6 — a repeat scan of the same
workspace must not re-query. Cache the metadata, never an artifact.

**`depaudit pkg` is the same code path phase 3's pre-flight calls** (plan 01
§9). One implementation of "is this package trustworthy", two invocation
contexts — otherwise the scanner and the gate drift and start disagreeing,
which is worse than having only one of them.

Ship 2e **after 2a**, not before. OSV is reactive: plan 01 §6 says a miss means
nothing, and the thread agrees detection lags publication by hours to days. The
age gate is what covers that window, and it is the control that works with no
network, no API, and no vendor. Intel is the complement, not the primary.

**Deliverables:** `Dockerfile`, `scripts/init-profile-state.sh`,
`scripts/verify-sandbox.sh`, `proxy/allowed_domains.txt`, `scripts/profile.sh`,
`justfile`, `scripts/depaudit.py` + fixtures, `ARCHITECTURE.md`,
`sandbox-hardening-package.md`, `.agents/skills/squid-management.md`.

### Phase 3 — Instrument the install window *(~2 days; blocked on G1)*

Extend `with-egress.sh`. This is the repo-unique deliverable.

**Prerequisite:** fix `reload_proxy` (G1) and confirm the fix live.

1. **Pre-flight.** Extract package specs from the command; run `depaudit pkg`
   (2e) against each — OSV `MAL-` check plus the local age/metadata signals.
   `BLOCK`-tier refuses to open the window. `REVIEW`-tier prints the signals and
   asks. Plan 02's 2-second hook budget does not apply — this is a human-driven
   window, seconds are affordable, so query serially and skip the concurrency
   machinery plan 01 §6 specifies for fleet scans.
2. **Bracket the window.** Record `date +%s` before opening and after closing.
3. **Snapshot.** Before: lockfile hashes, `node_modules/` and `site-packages/`
   top-level listings. After: the same.
4. **Egress diff.** Filter `access.log` (field 1 is epoch seconds) to the
   bracket, extract the distinct destination hosts. Timestamp-filtering rather
   than byte-offsets survives the proxy restart in step G1's fix. Anything
   outside `{registry, CDN}` during an install window is exactly plan 02 §Gate
   4's high-signal, low-FP evidence — and here it is *observable* rather than
   theoretical, because the window is explicit and narrow.
5. **Filesystem diff.** New top-level dirs not accounted for by the lockfile
   delta — plan 02 §Gate 4's "files present that no package declares."
6. **Persist.** Append one JSON line per window to
   `~/.ai-sandbox/profiles/<profile>/audit/depgate.jsonl`. **Host side, not
   tmpfs** — this is the fix for G7. Per AGENTS.md's state-placement rule:
   losing it would hurt, so it does not live in a container layer.

`profile.sh <p> deps --history` reads it back.

**Deliverables:** `scripts/with-egress.sh`, `scripts/profile.sh`,
`scripts/init-profile-state.sh` (create `audit/`), `ARCHITECTURE.md` state
table, `.agents/skills/squid-management.md`, `docs/index.md`.

### Phase 4 — Python script gate, staged *(deferred; see §6)*

`PIP_ONLY_BINARY=:all:` / `--only-binary :all:`. Highest-value remaining
control, highest friction on this image. Gate it behind phase 3's telemetry:
run `depaudit`'s `P08` (sdist detection) across the real profiles first and see
how many packages actually resolve to sdists. If the number is small, impose it.
If it is large, impose it per-project instead of image-wide. **Do not decide
this in advance of the data.**

---

## 6. Friction and risk, stated up front

| Change | Risk | Mitigation |
|---|---|---|
| `min-release-age=7` | Blocks legitimate same-week releases. Plan 02 §Gate 2 gotcha 2: **cannot be scoped per registry** — internal/private packages get held back too, and npm has no exclusion list beyond `min-release-age-exclude` | Start at 7, not 14. `min-release-age-exclude` exists in npm 12 (`npm config ls -l` confirms) — use it with a mandatory reason comment per plan 02 §2 |
| `save-exact=true` | Changes resolution semantics for every new install | Low risk; makes lockfile diffs reviewable, which is the point |
| Phase 1b manifest rule | **False positives are the adoption killer** (plan 02 §8). A version bump must not trip it | The regex targets `"name": "<specifier>"` introductions. Test 1d's version-bump case is the gate on merging |
| `locked` egress mode | Breaks on-the-fly `uv run` resolution, `container_testing`'s uv project, and any `pnpm run build` that installs | Default `dev`. Opt one profile in first. Do not flip the repo default until it has been lived on |
| `PIP_ONLY_BINARY=:all:` | Breaks any sdist-only dependency. On a CUDA/ML image that is a live risk | Phase 4, data-driven, possibly per-project |
| **OSV `MAL-` as a block** (2e) | **The one way this "can only help" is false.** A wrongly-published `MAL-` record on a popular package, wired to `--fail-on block`, breaks the build for a legitimate dependency — and per plan 02 §8, FP rate is the number that decides whether any of this survives. The reported May 2026 withdrawal of 157 records (FastAPI, Strawberry GraphQL, rdflib) is the worked example | Honour `withdrawn` (D6); keep 2d's extended known-good corpus green; `DEPGATE_OVERRIDE=<reason>` break-glass per plan 02 §6, logged. **Do not** gate `verify` (tier 1) on a network call — an unreachable OSV must never fail an `up` |
| OSV as a *source of confidence* | It is reactive. A clean result means "nothing known yet", not "safe" — plan 01 §6 is explicit that a miss means nothing | Report `NO-KNOWN-MAL`, never `PASS`. The age gate, not the intel feed, is what covers the unknown window |
| Everything in phase 1 | Touches `claude-settings.json` + hooks | AGENTS.md: hook edits require `deny-destructive.test.sh` green, and security-sensitive files require the commit message to state security impact + `profile.sh <p> verify` |

**Two things the incoming plans promise that this plan does not deliver**, per
plan 02 §9: a patient squatter who registers a plausible name and waits out the
quarantine, and compromise of an already-trusted dependency. Neither age gates
nor egress containment touch those. The control that does is a human deciding
each new dependency deliberately — which is what phase 0 and phase 1b exist to
force, and why 1b blocks rather than warns.

---

## 7. Sequencing and effort

| Phase | Deliverable | Effort | Depends on |
|---|---|---|---|
| 0 | Rules in `agent-notice.md`, synced | ~1h | — |
| 1 | Gate 0 holes closed + tests | ~0.5d | — |
| 2a–2d | Gate 2 config + tripwires + `depaudit posture` + fixtures | ~2–3d | — |
| 2e | `depaudit pkg` + OSV `MAL-` cross-check | ~0.5d | 2c (shares the CLI + cache) |
| G1 | `with-egress.sh` reload fix | ~2h | live repro |
| 3 | Install-window instrumentation + persistent audit log | ~2d | G1, 2e |
| 4 | Python wheels-only, staged | TBD | 3 (telemetry) |

Phases 0, 1, 2 are parallel. **Do phase 1 first regardless** — it is half a day,
it closes the manifest-edit path which is the acute unguarded risk, and per plan
02 §7 it produces the telemetry that tells you where to set every other
threshold.

**On sequencing 2e:** it is the cheapest unit here and it is tempting to do it
first, because a verified-working free API is more satisfying to build than an
`.npmrc` line. Resist that. 2a is the control that covers the window where every
intel feed structurally fails — the days between publication and detection — and
2e without 2a is a system that catches only what someone else already caught.

Per plan 02 §7: **nothing starts in blocking mode except phase 1b/1c**, which
block because a dependency addition is a trust-boundary change that should
always be a named human act — not because a signal fired.

---

## 8. Open decisions

1. **`locked` vs `dev` egress default** (2b) — a repo-policy call. Recommendation:
   ship both, default `dev`, opt `nranthony` in first.
2. **Quarantine window** — 7 days both ecosystems, or 7/14 split by plan 02's
   `high_risk_days`? Recommendation: flat 7 until there is data to justify the
   complexity.
3. **Cross-port to macolima** — phases 0, 1, and 2a are portable; phase 3 is not
   (macolima's egress topology differs). Per golden rule 3, cross-check the
   `deny-destructive.sh` additions against the sibling before merging, and keep
   them bash-3.2-safe (D5).
4. **Does `depaudit` live here or in its own repo?** It is useful to every repo,
   not just the sandbox — see
   [`04-portable-guardrails-outside-sandbox.md`](04-portable-guardrails-outside-sandbox.md) §5.
5. **A second intel source, ever?** OSV is free, keyless, and costs no egress
   surface (D6). Socket adds behavioural detection OSV structurally cannot have,
   at the cost of a vendor in the trust path. Recommendation: ship 2e, let phase
   3's audit log accumulate for a month, and decide from the observed `MAL-` hit
   rate. If OSV never fires, a second source is not the missing piece — the age
   gate is already doing the work.
