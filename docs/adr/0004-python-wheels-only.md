# ADR-0004: Python installs are wheels-only by default; source builds are opted into per project

- Status: Accepted
- Date: 2026-08-03
- Deciders: nranthony + agent
- Implements: [`work/0001-dependency-guardrails/plan.md`](../../work/0001-dependency-guardrails/plan.md) T23 (phase 4)
- Related: [ADR-0003](0003-strict-egress-default.md) (registries closed by default)

## Context

An sdist (source distribution) runs `setup.py` — or an arbitrary PEP-517 backend — at
**install** time. That is the exact Python analogue of an npm lifecycle script, which this
image already blocks (`allow-scripts` empty; pnpm 10 blocks by default). A wheel is inert:
unpacked, not executed. So Python had a hole where Node had a gate, and gap G6 recorded it.

The plan deliberately refused to decide this in advance: *"Small → impose image-wide. Large
→ impose per-project. Do not decide this in advance of the data."*

**The data that existed was wrong.** `depaudit`'s `P08` counted any package whose lockfile
entry contained an `sdist` key. Nearly every package on PyPI publishes an sdist *alongside*
its wheels, and uv installs the wheel — so the check was measuring "publishes an sdist",
not "builds from source". On that basis `dashboard` was recorded as having "45 sdists" and
image-wide enforcement was judged not viable. Its true count is **zero**.

Re-measured across 16 real lockfiles in the live profiles:

| | Count | Share |
|---|---|---|
| Distinct packages | 565 | — |
| Publish an sdist (the old, wrong metric) | 522 | 92.4% |
| **Have NO wheel — must build from source** | **6** | **1.1%** |

The six: `antlr4-python3-runtime`, `bibtexparser`, `forbiddenfruit`, `python-louvain`,
`sgmllib3k`, `tavily`. They appear in 5 of 16 projects.

So the decision rule pointed both ways at once: 1.1% of packages is unambiguously "small",
while 31% of projects needing an exemption is not. What resolved it is that the six are a
**known, named, bounded set** — an exemption list is tractable, and every *future* sdist
gets stopped by default rather than silently built.

## Decision

**Refuse source builds by default, image-wide. Projects that need one opt out explicitly.**

Both installers are configured, because they share no configuration — verified: uv reads
**no** pip config at all.

| Tool | Where | Setting |
|---|---|---|
| uv (primary) | `/etc/uv/uv.toml` | `no-build = true` |
| pip | `/etc/pip.conf` | `only-binary = :all:` |

Escape hatches, both measured rather than assumed:

- **uv has no per-package exemption key.** `no-build-package` is the *narrowing* form
  (forbid these), not an allowlist. A project opts out wholesale with `no-build = false` in
  its own `uv.toml` or `[tool.uv]`; this overrides the system default. Verified.
- **pip does support per-package exemption**: `no-binary = <name>` alongside
  `only-binary = :all:` exempts that one package. Verified.

An exemption is legitimate. An *invisible* one is not: `verify` warns when `/etc/pip.conf`
carries a `no-binary` list, and `depaudit`'s `P08` names every package in a project that
can only build from source. Same discipline as npm's `allow-scripts` allowlist.

## Consequences

- **Five projects break until they opt out**: `job_search_agent`, `numerai`, `shrec`,
  `citation_tools`, `wearable_publications`. This is the control working, not a regression.
  The fix is two lines in each project's `uv.toml`, and it forces someone to notice that
  the dependency executes code at install time.
- The failure is loud and specific under uv: *"Wheels are required for `sgmllib3k` because
  building from source is disabled for all packages"*.
- **pip's failure message is a trap.** It reads `Could not find a version that satisfies
  the requirement X (from versions: none)` — indistinguishable from the package not
  existing, which is exactly what a slopsquat miss looks like. Anyone debugging a
  "nonexistent package" under pip should check this ADR before concluding the name is
  wrong. uv's message is the reason to prefer uv here.
- `verify` gains two tripwires (36 → 38 checks). Both are asserted separately because
  checking one would leave the other silently open.
- ML/CUDA packages are unaffected in practice — torch, numpy, scipy and friends all ship
  manylinux wheels. The friction lands on small pure-Python packages whose maintainers
  never uploaded one.

## Alternatives considered

- **Leave it unset** (the pre-existing state). Rejected: it left Python with no
  install-time execution gate at all while Node had one, on measured evidence that the cost
  is 1.1% of packages.
- **Per-project only, no image default.** Rejected: it protects only the projects someone
  remembers to configure, which is the opposite of a default-deny. The whole value is that
  the *next* dependency without a wheel is stopped before anyone thinks about it.
- **Image-wide with a global exemption list for the known six.** Not available for uv — no
  such key exists — and undesirable anyway: it would grant a build exemption to five
  projects that do not need it in order to serve the one that does.
- **Block at the proxy instead** (refuse `.tar.gz` from PyPI). Rejected: Squid gates hosts,
  not artifact types, and adding content inspection to the egress path contradicts
  [ADR-0002](0002-dependency-guardrail-scope.md).
