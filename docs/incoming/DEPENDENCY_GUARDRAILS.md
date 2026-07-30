# Dependency Guardrails — Slopsquatting Defense

> **Status:** Proposal / suggestions. Nothing here is enforced yet.
> **Audience:** AI coding agents operating in this repo, and the humans reviewing their PRs.
> **Where this lives:** drop this file at the repo root, or inline the "Rules" section into
> `AGENTS.md` / `CLAUDE.md` / `.cursorrules` so the agent actually reads it on every session.

---

## 1. The threat, briefly

**Slopsquatting** is a supply-chain attack that targets AI-generated code specifically.
LLMs invent plausible-sounding package names (`react-form-validator-utils`,
`express-async-wrapper`, `{popular-lib}-utils`). Attackers register those names on npm
with a malicious `postinstall` script and wait.

Why it needs its own row in the threat model rather than a footnote under typosquatting:

- Roughly **1 in 5** AI-recommended packages doesn't exist on the registry.
- Around **43%** of those hallucinated names **repeat across prompts** — they're predictable,
  so they're squattable at scale.
- About half look nothing like any real package, so **similarity/typo scanners won't flag them**.
- When an agent installs autonomously, the human verification step is simply absent. The attack
  completes with zero human interaction.

The payload is usually a `postinstall` script that exfiltrates `.env` files or credentials
during `npm install` — no prompt, no warning, nothing unusual in terminal output.

---

## 2. Rules for the agent

These are the behavioral rules. They cost nothing to adopt — no new tooling, just discipline.

### 2.1 Never add a dependency silently

If a task appears to require a new package, **stop and surface it** rather than installing.
State the package name, what it's for, and why an existing dependency won't do. A new
dependency is a change to the project's trust boundary, not an implementation detail.

### 2.2 Verify existence and provenance before proposing

Before suggesting *any* package not already in `package.json`, run:

```bash
npm view <pkg> time.created time.modified versions repository homepage maintainers
```

Reject or escalate if **any** of these hold:

| Signal | Why it matters |
|---|---|
| `npm ERR! 404` | The package doesn't exist. You hallucinated it. Do not create a placeholder or suggest a "similar" name — find a real alternative. |
| Created within the last ~6 months | Squats are freshly registered against recently-popular hallucinations. |
| Fewer than ~3 published versions | Real maintained packages accumulate releases. |
| No `repository` field / dead link | Legitimate packages almost always link to source. |
| Negligible weekly downloads relative to its claimed purpose | A "popular utility" with 40 downloads/week isn't one. |
| Name matches `{real-lib}-{ai,gpt,helper,utils,wrapper}` | This is the canonical LLM naming pattern and the highest-yield squat target. |

Cross-check download history on `npmjs.com/package/<pkg>` — the CLI doesn't surface it well.

### 2.3 Never run bare `npm install` in CI or scripted contexts

Use `npm ci`. It installs strictly from `package-lock.json`. This is the single highest-value
control: a hallucinated name suggested mid-task **cannot** silently enter a build. It must
arrive as a reviewable lockfile diff on a pull request.

### 2.4 Treat package installation as a privileged operation

If running in an autonomous or bypass-permissions mode, dependency installation is **out of
scope** without explicit per-package human approval. Generating code is reversible; running an
attacker's `postinstall` on the developer's machine is not.

### 2.5 Don't propagate unverified names into documentation

`AGENTS.md`, `CLAUDE.md`, `SKILL.md`, `.cursorrules`, `.mdc`, and `README.md` are attack
surfaces. An install command written into an instructions file gets executed by future agents
and copy-pasted by future humans, long after anyone remembers where the name came from. Every
`npm install X` appearing in a docs or config file is subject to the same §2.2 verification.

---

## 3. Suggested repo changes

Sequenced by effort-to-payoff. The first two need no new dependencies.

### Tier 1 — configuration only

**`.npmrc`** (repo root)

```ini
# Block postinstall/preinstall scripts by default — this is where the payload runs.
ignore-scripts=true

# Pin resolution to the official registry (or your internal mirror).
registry=https://registry.npmjs.org/

# Refuse to silently rewrite the lockfile.
save-exact=true
```

> ⚠️ **Tradeoff:** `ignore-scripts=true` will break packages with legitimate native build
> steps (`esbuild`, `sharp`, `bcrypt`, `puppeteer`, Prisma). Expect to run
> `npm rebuild <pkg>` for those explicitly. That friction is the point — it makes script
> execution a deliberate, named act. If it proves untenable, drop this line and lean harder
> on Tier 2 scanning instead.

**`.github/CODEOWNERS`** *(adjust path if not using GitHub)*

```
package.json      @your-team/security
package-lock.json @your-team/security
.npmrc            @your-team/security
```

Makes every dependency change merge-blocking on human review. Agent-authored dependency
additions can no longer land unseen.

### Tier 2 — automated scanning

**Pre-commit hook** — via Husky, or `.git/hooks/pre-commit`:

```bash
#!/bin/sh
npx slopcheck . || {
  echo "Phantom package detected. Run 'npx slopcheck . --fix' and re-commit."
  exit 1
}
```

`slopcheck` validates npm names in `package.json` *and* in markdown/config files against the
live registry, and flags unpublished names (takeover risk) alongside nonexistent ones.

**`.github/workflows/dependency-audit.yml`**

```yaml
name: Dependency Audit
on: [push, pull_request]

jobs:
  slopsquat-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: 'npm'

      # Strict lockfile install — fails if package.json and lockfile disagree.
      - run: npm ci --ignore-scripts

      # Registry existence check across source, config and docs.
      - run: npx slopcheck . --json

      # Known-vulnerability pass. Note: this does NOT catch slopsquats —
      # a brand-new malicious package has no CVE. It's a separate layer.
      - run: npm audit --audit-level=high
```

**Full-tree SCA.** Hallucinated names sometimes arrive as *nested* dependencies and never
appear in `package.json`. Add Socket.dev, Snyk, or Aikido to scan the resolved tree, not just
direct deps. Aikido SafeChain additionally wraps `npm`/`npx`/`yarn`/`pnpm` to intercept
installs against threat intel before anything touches the machine — worth considering for
local developer environments, not just CI.

### Tier 3 — organizational

- **Registry proxy** (Verdaccio, Artifactory, GitHub Packages) so resolution is controlled and
  auditable, with an explicit allowlist of external packages.
- **Sigstore provenance** as an audit layer — `npm publish --provenance` (CLI 9.5.0+) links a
  version to its exact source commit and CI build in the public Rekor transparency log.
  Prefer packages that publish with provenance where a choice exists.
- **Internal package allowlist** committed at repo root (`.slopcheck`) so scanners don't
  false-positive on private packages that aren't on any public registry.

---

## 4. Auditing what's already in the tree

Run once now, then quarterly:

```bash
# 1. Full resolved tree, including transitive deps.
npm ls --all > /tmp/tree.txt

# 2. Every package with an install-time script — the payload surface.
grep -rl '"postinstall"\|"preinstall"\|"install"' node_modules/*/package.json

# 3. Age and provenance of anything unfamiliar.
npm view <pkg> time.created repository maintainers

# 4. Packages present on disk but absent from the lockfile — a strong red flag.
npm ci --dry-run
```

For step 2, note that a match isn't itself evidence of malice — native modules legitimately
use install scripts. Read the script. A build step compiles; a payload reaches for
`process.env`, the filesystem outside its own directory, or the network.

---

## 5. Red-flag checklist for reviewers

A dependency addition in a PR warrants a hard stop if it is:

- [ ] Not present in the lockfile diff, but present in `package.json` (or vice versa)
- [ ] Added in the same commit as unrelated feature work, without mention in the description
- [ ] Registered on npm within the last few months
- [ ] Missing a repository link, or the link 404s
- [ ] Named after a real library with a generic suffix appended
- [ ] Introducing a `postinstall` script for a package that has no native build step
- [ ] Justified in the PR body only as "needed for X" with no evaluation of alternatives

---

## 6. Tailoring notes

This was written against a conventional Node layout. Adjust before committing:

- **Package manager** — examples assume npm. For pnpm use `pnpm install --frozen-lockfile`;
  for Yarn Berry, `yarn install --immutable`. Both have their own script-blocking settings.
- **Monorepos** — with workspaces, apply `.npmrc` at the root but expect per-workspace
  `package.json` files to each need CODEOWNERS coverage.
- **CI provider** — the workflow above is GitHub Actions; the three steps port directly to
  GitLab CI, CircleCI, or Buildkite.
- **Node version** — pinned to 22 above; match your `.nvmrc` or `engines` field.
- **Team handle** — replace `@your-team/security` in CODEOWNERS.
