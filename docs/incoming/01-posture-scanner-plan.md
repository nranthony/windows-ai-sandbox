# Post-Hoc Dependency Posture Scanner — Design Plan

**Codename:** `depaudit`
**Scope:** Node (npm/pnpm/yarn/bun) and Python (pip/uv/poetry/pdm/pipenv) repos.
**Status:** Design. Not built.

Answers two independent questions per repo, and reports them separately because they
have different owners and different remediation timelines:

1. **Posture** — which controls are configured? *(platform/infra fix, mechanical, fast)*
2. **Inventory** — what is actually resolved into the tree, and does any of it look like
   a squat? *(per-package human judgment, slow)*

---

## 1. Design constraints

These are load-bearing, not preferences.

| Constraint | Rationale |
|---|---|
| **Zero third-party dependencies.** Python 3.11+ stdlib only (`urllib`, `json`, `tomllib`, `concurrent.futures`, `hashlib`). | A supply-chain audit tool with its own dependency tree is self-defeating. It must be auditable by reading it, and immune to the attack it detects. |
| **Read-only against the target repo.** | Never mutates, never installs. |
| **Never runs a package manager install to enumerate.** Lockfiles are parsed, not executed. | `npm ls` requires a populated `node_modules`; `pip freeze` requires an environment. Building one *is* the dangerous act. Static lockfile parsing is the whole point. |
| **Degraded offline mode.** | Posture checks are purely local and must work with no network. Inventory enrichment needs registry access; when unavailable, emit `UNKNOWN` rather than `PASS`. |
| **Cache-first, fleet-scalable.** | A 200-repo scan must not issue 200× redundant registry lookups. |
| **Machine-readable primary output.** | Markdown is for humans; JSON is the interface for fleet rollup and trend tracking. |

---

## 2. Pipeline

```
discover ──▶ posture ──┐
    │                  ├──▶ score ──▶ report
    └──▶ inventory ──▶ enrich ──┘
         (local)      (network)
```

`posture` and `inventory` are independent and parallelizable. Only `enrich` touches
the network.

---

## 3. Module: `discover`

Fingerprint the repo before checking anything, so checks aren't reported as failures
for toolchains the repo doesn't use.

| Marker | Implies |
|---|---|
| `package-lock.json` | npm |
| `pnpm-lock.yaml` | pnpm |
| `yarn.lock` + `.yarnrc.yml` | Yarn Berry (v2+) |
| `yarn.lock` alone | Yarn Classic (v1) — **EOL, flag separately** |
| `bun.lock` / `bun.lockb` | Bun |
| `uv.lock` | uv |
| `poetry.lock` | Poetry |
| `pdm.lock` | PDM |
| `Pipfile.lock` | Pipenv |
| `requirements*.txt` only | bare pip — **weakest posture, no native gates** |
| `packageManager` field in package.json | authoritative; prefer over marker inference |

Also record: monorepo shape (workspaces / `pnpm-workspace.yaml` / `[tool.uv.workspace]`),
CI provider, and whether multiple package managers are present (a real finding — competing
lockfiles mean one is stale and unenforced).

**Edge case:** more than one Node lockfile present. Report as `CRITICAL-POSTURE`. It means
resolution is nondeterministic depending on who runs what.

---

## 4. Module: `posture`

Purely local. Reads config files and CI definitions. Every check emits
`PASS | FAIL | N/A | UNKNOWN` with the file and line that produced the verdict, so findings
are actionable without re-investigation.

### 4.1 Node checks

| ID | Check | Where | Pass criteria |
|---|---|---|---|
| `N01` | Install scripts blocked | `.npmrc` | `ignore-scripts=true` |
| `N02` | Resolution age gate | `.npmrc` | `min-release-age` set (npm ≥ 11.10.0 required — verify separately) |
| `N02p` | Age gate (pnpm) | `package.json` / `.npmrc` | `minimumReleaseAge` set, in **minutes** |
| `N02y` | Age gate (Yarn) | `.yarnrc.yml` | `npmMinimalAgeGate` set, in minutes |
| `N02b` | Age gate (Bun) | `bunfig.toml` | `minimumReleaseAge` set |
| `N03` | CLI version supports the gate | `packageManager`, CI setup steps | npm ≥ 11.10.0 / pnpm ≥ 10.16 / Yarn ≥ 4.10.0 / Bun ≥ 1.3 |
| `N04` | Registry pinned | `.npmrc` | `registry=` set to internal proxy, not defaulted |
| `N05` | No scoped registry sprawl | `.npmrc` | Each `@scope:registry` is a known-internal host |
| `N06` | Lockfile committed | git + `.gitignore` | lockfile tracked, not ignored |
| `N07` | Strict install in CI | workflow files | `npm ci` / `--frozen-lockfile` / `--immutable`; **no bare `npm install`** |
| `N08` | Yarn hardened mode | `.yarnrc.yml` | `enableHardenedMode: true` |
| `N09` | pnpm strict builds | `package.json` | `strictDepBuilds` / explicit `onlyBuiltDependencies` allowlist |
| `N10` | Updater cooldown | `renovate.json` / `dependabot.yml` | `minimumReleaseAge` / `cooldown.default-days` present — **enforced independently of the package manager gate** |
| `N11` | Exemption list is justified | `minimumReleaseAgeExclude`, `npmPreapprovedPackages`, `onlyBuiltDependencies` | Every entry has an adjacent comment |

### 4.2 Python checks

| ID | Check | Where | Pass criteria |
|---|---|---|---|
| `P01` | Wheel-only install policy | `pip.conf` / CI | `--only-binary :all:` — the pip analogue of script blocking, since wheels don't execute at install while sdists run `setup.py` at build |
| `P02` | Hash pinning | `requirements*.txt` | Every entry carries `--hash=sha256:…`; `require-hashes` set |
| `P03` | Lockfile present | repo root | `uv.lock` / `poetry.lock` / `pdm.lock` / hash-pinned requirements |
| `P04` | Age gate | `pyproject.toml` | uv `exclude-newer` set. **pip has no native equivalent — must be proxy-enforced.** Emit `N/A + escalate` for bare pip. |
| `P05` | Index pinned | `pip.conf`, `pyproject.toml` | `index-url` → internal mirror |
| `P06` | **No `extra-index-url`** | `pip.conf`, CI env | Absent. `extra-index-url` is a dependency-confusion vector: pip may prefer whichever index offers a higher version. Treat presence as `CRITICAL`. |
| `P07` | Strict CI install | workflow files | `uv sync --frozen` / `poetry install --sync` / `pip install --require-hashes -r` |
| `P08` | No sdists resolved | lockfile | Flag every dependency resolving to `.tar.gz` rather than `.whl` — each is arbitrary code at build time |

### 4.3 Cross-cutting checks

| ID | Check | Detail |
|---|---|---|
| `X01` | Manifests under CODEOWNERS | `package.json`, lockfiles, `pyproject.toml`, `requirements*.txt`, `.npmrc`, `pip.conf` all require review |
| `X02` | Pre-commit gate present | `.pre-commit-config.yaml` / `.husky/` invoking a dependency check |
| `X03` | Agent hook config present | `.claude/settings.json` with `PreToolUse`, `.codex/config.toml` approval policy |
| `X04` | **Agent instruction files audited** | Extract every install command from `AGENTS.md`, `CLAUDE.md`, `SKILL.md`, `.cursorrules`, `.mdc`, `.github/copilot-instructions.md`, `README.md`, `CONTRIBUTING.md`, and `docs/**`. These are executable surfaces — an agent reads them and acts. Every extracted name goes through `enrich` exactly like a manifest entry. |
| `X05` | Docs/manifest divergence | Package named in docs but absent from manifests = phantom instruction. Present in manifest but never in docs = undocumented trust decision. Both are findings. |
| `X06` | Lockfile ↔ manifest agreement | Dry-run parse; any manifest entry unrepresented in the lockfile means the next install resolves fresh and ungated |
| `X07` | Dependency-add provenance | `git log -p` on manifests: for each added dependency, record commit, author, whether the lockfile changed in the same commit, and whether the message references an issue. Dependency additions bundled into large feature commits are the pattern that hides agent-added packages. |

---

## 5. Module: `inventory`

Resolve the full tree — including transitives — from lockfiles only.

| Source | Parse target |
|---|---|
| `package-lock.json` (v2/v3) | `packages` map; key path gives the dependency chain |
| `pnpm-lock.yaml` | `packages` + `importers`; hand-rolled minimal YAML subset parser (no PyYAML — see constraints) |
| `yarn.lock` | Berry = YAML-ish; Classic = custom format. Two parsers. |
| `bun.lock` | JSONC (text) — strip comments. `bun.lockb` is binary: **fail loudly**, ask for a text lockfile, do not shell out to `bun`. |
| `uv.lock` | TOML via `tomllib`; `[[package]]` blocks carry `sdist`/`wheels` — directly feeds `P08` |
| `poetry.lock` | TOML; `[[package]]` + `[metadata.files]` |
| `Pipfile.lock` | JSON; `default` + `develop` |
| `requirements*.txt` | Line parse; resolve `-r` includes recursively; capture `--hash` presence |

Emit per package: `name`, `version`, `ecosystem`, `resolved_url`, `integrity`,
`direct|transitive`, `dependency_path[]`, `dist_kind` (wheel/sdist/tarball),
`declares_install_script`.

**Attribution matters most here.** A hallucinated name arriving as a transitive dependency
never appears in `package.json`, so the report must always show the chain that pulled it in —
that determines whether the fix is "remove this" or "talk to the maintainer of the thing
that depends on it."

---

## 6. Module: `enrich`

The only network stage. Per unique `(ecosystem, name)`:

**Endpoints** (unauthenticated, no key required):
- npm: `https://registry.npmjs.org/<name>` → `time.created`, `time.modified`, `versions`,
  `repository`, `maintainers`, `dist-tags`, per-version `dist.attestations`
- npm downloads: `https://api.npmjs.org/downloads/point/last-week/<name>`
- PyPI: `https://pypi.org/pypi/<name>/json` → `info.project_urls`, `releases` (timestamps),
  `info.yanked`, `urls[].packagetype`
- Cross-ecosystem: `deps.dev` for OpenSSF Scorecard signals
- Known-malicious: `OSV.dev` batch query — reactive, so a miss means nothing

**Behavior:**
- Concurrency ~10, with backoff. Registries rate-limit and this is a shared resource.
- Content-addressed cache keyed `(ecosystem, name, date)` with a 24h TTL, in a shared
  volume so fleet scans hit it once. Cache the *metadata*, never the artifact.
- 404 → `NONEXISTENT`. Distinguish from network failure, which is `UNKNOWN`.
- Also query **the other ecosystem** for the same name. Roughly 8.7% of Python names
  hallucinated by models exist on npm, so a Python dependency whose name resolves on npm
  but not PyPI is a strong cross-registry-confusion signal.

---

## 7. Module: `score`

Signals, ordered by discriminating power. Not additive-scored into a single number — the
report shows which signals fired, because "why" determines the remediation.

| Signal | Weight | Notes |
|---|---|---|
| Name 404s on target registry | **BLOCK** | Pure hallucination. If it's in a lockfile, resolution is already broken. If it's in docs, it's an unclaimed squat target — register a defensive placeholder or fix the docs. |
| Present in OSV/intel as malicious | **BLOCK** | |
| Yanked / security-held / unpublished | **BLOCK** | An unpublished name is re-registerable by anyone |
| Name resolves in the *other* ecosystem only | **BLOCK** | Cross-registry confusion |
| First published < 90 days ago | **REVIEW** | Strongest single signal available at t=0 |
| Fewer than 3 released versions | REVIEW | |
| No `repository` field, or link 404s | REVIEW | Legitimate packages nearly always link source |
| Single maintainer, account < 1 year old | REVIEW | |
| Weekly downloads < 500 | REVIEW | Weak alone; strong combined with youth |
| Matches `{known-lib}-{ai\|gpt\|helper\|utils\|wrapper\|tools\|client\|sdk}` | REVIEW | Canonical LLM naming pattern |
| Levenshtein ≤ 2 from a top-5000 package | REVIEW | Catches typosquats. Will **not** catch ~half of slopsquats, which resemble nothing real. |
| Declares install/postinstall script | CONTEXT | Not suspicious alone — native modules need it. Escalates everything else. |
| Resolves to sdist, not wheel | CONTEXT | Arbitrary code at build time |
| Appears in docs but no manifest | REVIEW | Phantom instruction |
| No provenance attestation | INFO | Absence is normal today; presence is positive evidence |

**Explicit non-signals** — do not include, they generate noise and false confidence:
`npm audit` / `pip-audit` CVE output. A package registered last Tuesday has no CVE. Run
them, but in a clearly separate section of the report labelled as a different control.

---

## 8. Module: `report`

Three outputs from one scan:

**`report.md`** — human. Leads with the five things to do this week, then posture gaps by
severity, then flagged packages with the evidence and the dependency chain. Everything that
`PASS`ed is collapsed to a single line — a report that reads mostly as failures is a report
people stop opening.

**`report.json`** — the interface. Stable schema, versioned. Feeds fleet rollup, trend
tracking, and dashboards.

**`report.sarif`** — for GitHub code scanning / equivalent, so findings land in the PR
diff rather than a separate tool.

**Fleet mode** (`depaudit fleet --manifest repos.txt`) aggregates: posture coverage per
control across the estate, the packages appearing in the most repos with `REVIEW`+ status
(highest-leverage single fixes), and repos with zero controls (start there).

---

## 9. CLI surface

```
depaudit scan <path>            # both phases, current repo
depaudit posture <path>         # local only, no network, fast, CI-friendly
depaudit inventory <path>       # tree + enrichment
depaudit pkg <eco> <name>       # single-package lookup, for ad-hoc use and hook reuse
depaudit fleet --manifest f     # multi-repo rollup

  --offline            posture only; inventory emits UNKNOWN
  --proxy URL          route registry lookups via the egress proxy
  --cache DIR          shared metadata cache
  --policy policy.yaml # shared with the gate system — see plan 02
  --fail-on {block,review,posture-critical,never}
  --format {md,json,sarif}
```

`depaudit pkg` is deliberately the same code path the `PreToolUse` hook calls. One
implementation of "is this package trustworthy," two invocation contexts — otherwise the
audit and the gate will drift and disagree.

---

## 10. Validating the scanner itself

A scanner nobody has tested against known-bad input is decorative. Ship fixtures:

- **Known-bad corpus:** `unused-imports` (npm, confirmed malicious, security-held),
  `events-channel`, and names from the USENIX hallucination dataset. Scanner must flag all.
- **Known-good corpus:** `express`, `requests`, `lodash`. Zero flags. Any flag here is a
  false-positive bug — track the rate, because false positives are precisely what cause
  teams to switch guardrails off.
- **Synthetic repos:** one with full posture (all `PASS`), one with none (all `FAIL`),
  one with each single control missing, one multi-lockfile, one monorepo.
- **Docs-only injection:** a fixture where the malicious name appears *only* in
  `AGENTS.md`. Exercises `X04`, the check most implementations miss.

Report false-positive rate in the release notes. It is the tool's most important number.

---

## 11. Phasing

| Phase | Deliverable | Effort |
|---|---|---|
| 1 | `discover` + `posture` + markdown report. No network. | ~2 days — immediate estate-wide visibility |
| 2 | `inventory` for `package-lock.json` and `uv.lock`/`requirements.txt` | ~3 days — covers most repos |
| 3 | `enrich` + `score` + JSON output | ~3 days |
| 4 | Remaining lockfile parsers, SARIF, fleet mode | ~1 week |
| 5 | Wire `depaudit pkg` into the hooks from plan 02 | ~1 day |

Phase 1 alone is worth shipping standalone. Knowing which of 200 repos have zero controls
is more actionable than a deep analysis of one.
