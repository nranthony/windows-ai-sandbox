# RFC: Portable Dependency Guardrails — Outside the Sandbox

- Status: Draft — **partially applied, no owning work item.** Its central claim held up:
  `scripts/depaudit.py` was built host-side and stdlib-only precisely so it runs against any
  repo with no sandbox, and it has been run against the `therapod` repos. The estate-wide
  rollout it argues for has no owner and no schedule.
- Author: external draft, imported 2026-07-30
- Applied so far: `depaudit` is portable by construction (plan §13 D3 keeps it in `scripts/`
  until a second repo needs it); `therapod`'s `engine` / `app_blast` / `app_zero` had the
  pnpm maturity window restored on branch `fix/supported-architectures` (2026-08-02).

**Companion to:** [`docs/_archive/dependency-guardrails-plan.md`](../_archive/dependency-guardrails-plan.md)
(formerly `03-sandbox-application-plan.md`).
**Question this answers:** of everything in the three imported documents, what
applies to **any** repo — pre-deployment development on the host, sibling
projects, work on a laptop — where there is no egress container and no Squid
allowlist?
**Build status:** Plan. Nothing implemented.

---

## 1. The split, in one table

Plan 02 §5 calls the no-container case "Topology B" and is blunt that it is
**advisory against a determined user**: `npm install --registry=https://registry.npmjs.org`
walks around any pinned registry, and there is no client-side fix. That is the
right frame. It is not a reason to skip these controls — the threat model here is
an *agent confidently installing a hallucinated package*, not an adversarial
developer, and against that threat client-side controls work fine.

| Control | Needs the sandbox? | Portable form |
|---|---|---|
| Behavioural rules for the agent | ❌ | `AGENTS.md` / `CLAUDE.md` block |
| `PreToolUse` hooks (install + manifest + docs) | ❌ | `~/.claude/settings.json` or repo `.claude/settings.json` |
| Age gate (`min-release-age` / `minimumReleaseAge` / `exclude-newer`) | ❌ | committed `.npmrc` / `pnpm` config / `pyproject.toml` |
| Install-script blocking | ❌ | npm 12 default; `--only-binary :all:` for Python |
| `npm ci` / `--frozen-lockfile` / `uv sync --frozen` | ❌ | CI + local discipline |
| CODEOWNERS on manifests | ❌ | `.github/CODEOWNERS` |
| `depaudit posture` scan | ❌ | stdlib-only, read-only, runs anywhere |
| **OSV `MAL-` cross-check** | ❌ | free, keyless, one stdlib POST — portable verbatim |
| Install-time interception (`sfw`) | ❌ | better fit *outside* the sandbox than in — §6 |
| PR red-flag checklist | ❌ | PR template |
| **Unbypassable registry pinning** | ✅ | — no client-side equivalent |
| **Install-window egress diff** | ✅ | — no egress visibility |
| **DNS-exfil closure** | ✅ | — |
| **Artifact inspection pre-execution** | ✅ | — |

Everything above the line is ~90% of the practical protection, and none of it
needs a container. The sandbox adds *enforcement* to controls that are otherwise
*conventions*.

---

## 2. Tier 1 — costs nothing, do it everywhere today

### 2.1 The behavioural rules

`DEPENDENCY_GUARDRAILS.md` §2 condensed. Five rules, no tooling:

1. **Never add a dependency silently.** Surface the name, the purpose, and why an
   existing dependency won't do. A new dependency is a change to the project's
   trust boundary.
2. **Verify existence and provenance before proposing** — `npm view <pkg>
   time.created versions repository maintainers`. A 404 means you hallucinated
   it; do not substitute a "similar" name.
3. **Never bare `npm install` in CI or scripted contexts** — `npm ci`,
   `pnpm install --frozen-lockfile`, `uv sync --frozen`. This is the single
   highest-value control in the whole document: a hallucinated name *cannot*
   silently enter a build, it must arrive as a reviewable lockfile diff.
4. **Installation is privileged.** In autonomous or bypass-permissions mode it
   is out of scope without per-package human approval. Generating code is
   reversible; running an attacker's `postinstall` is not.
5. **Don't propagate unverified names into docs.** `AGENTS.md`, `CLAUDE.md`,
   `SKILL.md`, `.cursorrules`, `README.md` are executable surfaces — an agent
   reads them and acts.

### 2.2 The distribution problem is already solved here

Plan 02 §5 names distribution and drift as the hard part of Topology B: *"a
`policy.yaml` in one repo doesn't propagate."*

**This estate already has the propagation mechanism.**
`scripts/sync-agent-notice.sh` injects a managed block from
`sandbox_templates/common/agent-notice.md` into repo `AGENTS.md` files and the
global `CLAUDE.md`. It is the org-wide-reusable-workflow pattern from plan 02,
in the form this setup actually uses.

Two consequences:

- **Put §2.1 in that template**, not in individual repos. One edit, whole estate,
  and re-running the sync detects drift.
- **That file is now a fan-out attack surface** — an unverified install command
  written into it reaches every repo. It needs the §2.1 rule 5 treatment more
  than any other file in the estate. This is the `X04` check from plan 01 with
  the blast radius multiplied, and it is specific to this setup.

### 2.3 Global agent hooks

The highest-leverage single move for a multi-repo estate, and it is genuinely
cheap: the `PreToolUse` hooks from
[`03-sandbox-application-plan.md`](../_archive/dependency-guardrails-plan.md) phase 1 are
plain POSIX shell reading JSON on stdin. Nothing about them is sandbox-specific
except the protected paths.

Put the dependency rules — install-command matcher, manifest-dep-add,
docs-install-command — in **`~/.claude/settings.json`** and they apply to every
repo on the host, including ones that have no `.claude/` directory and no
guardrails of their own. A per-repo `.claude/settings.json` then layers
repo-specific additions on top.

Plan 02's warning applies and is worth repeating: **scope the matchers tightly.**
Broad matchers fire on every Bash call, and the resulting false positives are the
most common reason people turn hooks off. A hook that gets disabled protects
nothing.

Also portable: the deny-message discipline. `"Blocked: not found on npm"`
produces a retry loop. `"Blocked: 'unused-imports' not on npm; you likely mean
'eslint-plugin-unused-imports' (8y old, 12M weekly)"` produces a correct fix.
Write hook messages *for a model to act on*.

### 2.4 Committed per-repo config

Ten lines, no dependencies, works on a plane.

`.npmrc`:
```ini
min-release-age=7                          # npm >= 11.10.0; npm 12 in our image
registry=https://registry.npmjs.org/       # or an internal mirror
save-exact=true
```
Do **not** add `ignore-scripts=true` on npm 12 — its `allow-scripts` allowlist is
empty by default and already blocks lifecycle scripts. Add it only for repos
pinned to npm ≤ 11, and expect to run `npm rebuild <pkg>` for `sharp`, `esbuild`,
`bcrypt`, `puppeteer`, Prisma. That friction is the feature: script execution
becomes a named act.

`package.json` (pnpm — note the unit is **minutes**, not days):
```json
{ "pnpm": { "minimumReleaseAge": 10080 } }
```

`pyproject.toml` (uv):
```toml
[tool.uv]
exclude-newer = "2026-07-01T00:00:00Z"
```
Per-project, not machine-wide. A global resolution freeze is a footgun.

`.github/CODEOWNERS`:
```
package.json      @owner
package-lock.json @owner
pnpm-lock.yaml    @owner
pyproject.toml    @owner
uv.lock           @owner
requirements*.txt @owner
.npmrc            @owner
```
Makes every dependency change merge-blocking on human review. This is what stops
agent-authored dependency additions landing unseen, and it is the control plan 02
§9 identifies as the *only* one that catches a patient squatter.

---

## 3. Tier 2 — CI is the enforcement point

Plan 02 §5 is right that without a container, **CI is the one execution
environment you fully control**. Everything client-side is fast feedback; CI is
where "advisory" becomes "blocking."

Minimum viable gate on every PR:

```yaml
- run: npm ci                     # or: pnpm install --frozen-lockfile
                                  #     uv sync --frozen
- run: python depaudit.py posture . --fail-on posture-critical
- run: python depaudit.py inventory . --fail-on block   # OSV MAL- over the resolved tree
- run: npm audit --audit-level=high   # separate control — see below
```

Four notes that matter more than the YAML:

- **`npm audit` / `pip-audit` do not catch slopsquats.** A package registered
  last Tuesday has no CVE. Plan 01 §7 lists CVE output as an explicit
  **non-signal** — run it, but in a clearly separate section labelled as a
  different control, or it generates false confidence.
- **The OSV cross-check is what makes that separation workable**, and it is
  portable verbatim — free, keyless, one stdlib POST. See
  [`03`](../_archive/dependency-guardrails-plan.md) §3 D6 for the verified API shape. The
  whole discipline is one line: **consume `MAL-` records, discard
  `GHSA-`/`PYSEC-`/`CVE-` on this path.** Honour `withdrawn` before blocking.
  `osv-scanner` is the batteries-included alternative if you would rather not
  write the client — outside the sandbox its Go binary costs nothing, whereas
  inside it violates the stdlib-only rule ([`03`](../_archive/dependency-guardrails-plan.md) §4).
- **Run the intel check over the resolved tree, not the direct deps.** Plan 01
  §5 is emphatic and it matters most here: a hallucinated name often arrives as
  a *transitive* dependency and never appears in `package.json` at all. Checking
  manifests only is the most common way this control gets implemented uselessly.
- **Fail closed in CI, fail open loudly locally** (plan 02 §6). A build that
  can't verify shouldn't ship. But fail-closed *local* tooling gets uninstalled
  within a week, and an uninstalled gate protects nothing.
- **Renovate/Dependabot cooldowns are configured separately** (plan 02 §Gate 2
  gotcha 1). The package-manager age gate fires at *install* time; the updater
  evaluates independently and will keep opening PRs that can't actually be
  installed. Renovate's `config:best-practices` preset already sets a 3-day npm
  default; Dependabot uses `cooldown.default-days`. Both exempt security updates.

---

## 4. Tier 3 — the reviewer's job

The one control that catches what none of the above do. From
`DEPENDENCY_GUARDRAILS.md` §5, as a PR template checklist:

- [ ] Present in `package.json` but not the lockfile diff, or vice versa
- [ ] Added in the same commit as unrelated feature work, unmentioned in the
      description *(this is the pattern that hides agent-added packages —
      plan 01 `X07`)*
- [ ] Registered within the last few months
- [ ] Missing a repository link, or the link 404s
- [ ] Named after a real library with a generic suffix appended
      (`{lib}-{ai,gpt,helper,utils,wrapper,client,sdk}`)
- [ ] Introduces a `postinstall` for a package with no native build step
- [ ] Justified only as "needed for X", with no evaluation of alternatives

---

## 5. `depaudit` should not live in the sandbox repo

Plan 01's constraints — **zero third-party dependencies, read-only against the
target, never runs a package manager to enumerate** — make it portable by
construction. Python 3.11+ stdlib runs on any host, in CI, in a container, on a
laptop offline (`--offline` degrades to posture-only and emits `UNKNOWN` rather
than `PASS`, which is the correct failure direction).

Its natural scope is *every repo*, not the sandbox. Two options:

- **Own repo, vendored by rev.** Cleanest; matches plan 02's "shared pre-commit
  hook repo pinned by rev." Costs a repo.
- **Live in windows-ai-sandbox, symlinked/copied out.** Cheaper to start, drifts
  eventually.

Recommendation: **build it in `windows-ai-sandbox/scripts/` for phase 2, extract
to its own repo the first time a second repo needs it.** Do not pre-build the
abstraction.

Whichever: a scheduled `depaudit posture` run across `~/repo/*` is the
compensating control for the missing chokepoint. Plan 02 §5 is explicit that the
scheduled scan *is* the thing that substitutes for a container in Topology B —
it detects repos that have drifted out of policy, which is the only failure mode
client-side config actually has.

---

## 6. What you lose outside the sandbox — say it out loud

So nobody assumes the portable subset is equivalent:

- **A pinned registry is a suggestion.** `--registry=` overrides it. No fix.
- **`postinstall` reaches the open internet.** Inside the sandbox it hits
  `TCP_DENIED`; on the host it exfiltrates `.env`, `~/.npmrc`, `~/.aws/credentials`
  and you find out later, if ever.
- **DNS exfil is wide open.** The sandbox sinkholes DNS; a host does not.
- **No install-window egress diff**, because there is no window and no proxy log.
- **Hookless agents are uncovered.** Copilot and Cursor have no deterministic
  gate. Inside the sandbox, Gates 1–3 cover them structurally. Outside, they are
  covered by config and CI only — which is the strongest argument in the whole
  set of documents for doing risky dependency work *inside* a profile rather than
  on the host.

The three mitigations that recover part of it, all cheap:

- **Credential canaries** (plan 02 §Gate 4) — a fake token in `.env`,
  `~/.npmrc`, `~/.aws/credentials`, alerting on use. One of the few post-install
  detections that works with no egress visibility at all.
- **Socket Firewall (`sfw`)** — proxies npm/yarn/pnpm/pip/uv/cargo and blocks
  known-malicious packages at install time, no API key. This is the **only**
  item in the whole set of documents that is a better fit *outside* the sandbox
  than inside it, and the reason is worth understanding: inside, it would be a
  third-party binary intermediating every install from within the security
  boundary, duplicating what the audited install window and lockfile inventory
  already do ([`03`](../_archive/dependency-guardrails-plan.md) §4). Outside, there **is**
  no window and no proxy — so an install-time interception layer is filling a
  genuine hole rather than adding a redundant one. Its strongest argument
  applies in both places though: your real exposure is the ~200 transitive
  dependencies, not the one package you chose. Any control that only inspects
  direct deps is theatre.
- **Do the install in a sandbox profile, then commit the lockfile.** Resolution
  and script execution happen behind the egress boundary; the host repo only
  ever receives a reviewed lockfile diff. This is the sandbox's most
  under-used capability and it requires nothing new to be built.

---

## 7. Suggested order

| # | Action | Effort | Where |
|---|---|---|---|
| 1 | Rules into `sandbox_templates/common/agent-notice.md`, run the sync | ~1h | estate-wide |
| 2 | Dependency hooks into `~/.claude/settings.json` | ~2h | host-global, all repos |
| 3 | `.npmrc` / pnpm / uv config committed per active repo | ~1h each | per repo |
| 4 | CODEOWNERS on manifests | ~15m each | per repo with a remote |
| 5 | PR template checklist | ~15m | per repo with a remote |
| 6 | `depaudit posture` in CI where CI exists | ~2h | per repo |
| 7 | OSV `MAL-` check over the **resolved tree** in the same CI job | ~0.5h once built | per repo |
| 8 | Scheduled estate scan over `~/repo/*` | ~1h | host |

Items 1 and 2 cover every repo at once and together are an afternoon. Everything
else is per-repo and can follow the work rather than lead it.

## 8. Host-trust checklist (folded in from `docs/incoming/`, 2026-08-03)

Triaged out of an unverified third-party checklist
(`post_gpt5-6-sol_sandbox_break_ai_security_checklist_02.md`, now in
[`docs/_archive/`](../_archive/)). Most of that document restated controls this
estate already has. These five sections did not, and they belong here rather than
in the sandbox repo's own docs **because every one of them is about the host —
the side of the boundary this RFC exists to cover.** Unowned, like the rest of
this RFC; recorded so the questions are not re-derived from scratch.

The framing worth keeping: the sandbox review has always asked *what can the
agent reach?* These ask *who trusts what the agent wrote?*

### Host-trust boundaries

- [ ] Files written by the agent are treated as untrusted until reviewed.
- [ ] Workspace configuration is not implicitly executable.
- [ ] Host-side automation that consumes workspace files is inventoried.
- [ ] Git hooks, task runners, venv launchers and similar helpers are reviewed for
      trust leakage.

Partially addressed inside the boundary already: the deny hook blocks writes to
`.git/hooks/` (rule 9b) precisely because git executes them later, and rules
15/16 exist because *config* is a form of executable surface. The open part is
host-side: `just` recipes, systemd units, cron jobs or editor tasks on the host
that read files an agent wrote in `~/repo/<profile>/`.

### Local daemons and helpers

- [ ] The agent cannot talk to privileged local daemons unless explicitly required.
- [ ] Docker socket, build daemons, language servers and local DBs are not exposed
      by default.
- [ ] Any daemon reachable from the sandbox is part of the attack surface.

Largely held today by `internal: true` plus the DNS sinkhole, and the rootless
socket is deliberately not mounted — see
[`docs/vscode-integration-security.md`](../vscode-integration-security.md) for the
socket-exposure analysis and Findings B/C. Worth re-checking whenever a new
sibling container is added, since anything on `sandbox-internal` is reachable by
name.

### Command policy

- [ ] Approval is based on the full invocation, not the command name alone.
- [ ] "Safe" commands are reviewed for side effects and helper execution.
- [ ] Shell, git, package managers and task runners are constrained by argument
      and context.

This one is **already answered, and the answer is written into the Dockerfile**:
`permissions.deny` keys on a command *prefix*, so it is routed around by any
wrapper — which is the whole reason the `deny-destructive` PreToolUse hook exists
(it sees the full command string). The checklist item is a good statement of why.
Outside the sandbox there is no equivalent, which is this RFC's §6 point.

### Provenance and trust handoffs

- [ ] The system records which files were created by the agent.
- [ ] It records which trusted helper later consumed those files.
- [ ] Execution events can be traced back to agent influence.
- [ ] The sandbox review includes host-side readers, not just the agent process.

Nothing covers this today, in or out of the boundary. The install-window audit
record (`depgate.jsonl`) is the nearest thing and is scoped to dependency
installs. Cheapest first step if this is ever picked up: agent-authored commits
are already attributable via `Co-Authored-By`, so the gap is really about
*non-git* artifacts.

### Review questions to re-ask periodically

- [ ] What can the agent write?
- [ ] Which host components trust those writes?
- [ ] Which local daemons can the agent reach?
- [ ] Which commands skip approval, and why?
- [ ] Is policy enforced on invocations or just names?
- [ ] Where can agent-created artifacts become host actions?
