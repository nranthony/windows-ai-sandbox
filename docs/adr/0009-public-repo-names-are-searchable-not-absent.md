# ADR-0009 — In a public repo the standard is SEARCHABLE, not "present at all"

- **Status:** Accepted (2026-08-25)
- **Date:** 2026-08-25
- **Relates to:** [ADR-0001](0001-provenance-tiers.md) — an ADR is required for
  anything affecting **public contracts**; what this repo publishes under a real
  client's name is one.
- **Affects:** `scripts/private-names-check.sh`, the gitignored
  `.private-names.local` (and its `.gitignore` entry), the `justfile`
  `test-offline` recipe, `AGENTS.md` "Public-repo constraints", and the surfaces
  that recipe scans.

## Context

This repo is public, and profile names double as real client/project names — the
same fact that keeps the vendored private tool and its skill gitignored. A
2026-08-24 case-insensitive re-audit found 27 occurrences across 13 tracked
files (`docs/_archive/0007-genericise-public-identifiers-spec.md`).

Roughly half of them were *evidence*, not leakage. `proxy/allowed_domains.txt`
annotates each workspace ID with the account it belongs to and why one entry was
UNVERIFIED; `sandbox-hardening-package.md` claimed a control was "verified inside
the `<name>` profile with …". Anonymising those turns a falsifiable claim into an
unfalsifiable one — the same class of loss as replacing a content diff with a
hash. So this was never a find-and-replace, and the question that actually needed
an owner decision was *how public is "public" here*: are the names a problem
because they are **searchable**, or because they **appear at all**?

The second half of the context is rate. Occurrences grew by 4 in 6 days between
the original 9-file audit and the re-audit — entirely through ordinary agent work
writing new comments that happened to name a client. A one-time cleanup does not
hold against that.

## Decision

**1. The standard is SEARCHABLE.** High-visibility surfaces carry no client name,
case-insensitively. Those surfaces are exactly: `README.md`, `ARCHITECTURE.md`,
`AGENTS.md`, `justfile`, `scripts/`, `sandbox_templates/`, `docs/index.md`,
`docker-compose*.yml`, `Dockerfile`, `seccomp.json`, and `proxy/`.

**2. It is NOT "present at all". Three categories are deliberately kept:**

- **Archived narrative, RFCs, and `work/*/`** — `docs/_archive/`, `docs/rfcs/`,
  `work/`, and `docs/*.md` outside `docs/index.md`. They record what happened and
  when; rewriting them to look tidier is a worse outcome than the disclosure.
- **Evidence-bearing uses** — `proxy/allowed_domains.txt`'s provenance comments,
  where the name **is** the checkable evidence. This is the one carve-out inside
  a scanned surface, and it is an explicit exclusion in the checker, not an
  accident of scope.
- **Git history** — never rewritten. The names are in past commits; that is a
  different and much larger decision. This is a going-forward gate.

Where a *user-facing* doc carried evidence, the fix was to rewrite it so the
checkable part survives without the name: `sandbox-hardening-package.md` now
pins the workspace ID (already established non-secret) and drops the profile name.

**3. Enforcement is a check, not vigilance.** `scripts/private-names-check.sh`
scans the point-1 list over `git ls-files` (tracked files only), case-
insensitively, and is wired into `just test-offline` as the ninth offline suite.

**4. The name list is never committed.** It loads from a gitignored
`.private-names.local`, one name per line, following the repo's existing
gitignored-pointer convention (`.depot-dir.local`, `.myclickup-dir.local`,
`.conventions-dir.local`). Committing the list would re-introduce precisely what
the check exists to catch.

**5. Unconfigured is a loud `[SKIP]`, exit 0 — and this check has only TWO
states,** unlike the three-state pointer rule in AGENTS.md's boundary-monitor
table, where "configured, target missing" is a FAIL. There is no third state
here: the file **is** the config, so its absence and "not configured" are the
same fact, and a clone that never had the list is the ordinary case rather than
a broken pointer. AGENTS.md's "a skip is not a pass" rule is satisfied by saying
so on the line itself — the skip text states that the check provides no coverage
until the owner creates the file.

## Consequences

- **A green `test-offline` on a clone without `.private-names.local` is not
  coverage.** It is a skip, and it prints as one. Anyone reading a CI summary for
  proof that no client name shipped must confirm the check was configured.
- **Adding a new client/profile name is a two-step job**: add it to the
  owner's `.private-names.local`, then re-run the check before the surfaces it
  scans are edited. Nothing in the tracked tree records the name, so no other
  contributor's checkout gains the protection automatically.
- **The scanned list and the deliberate keeps must move together.** The surface
  list lives in three places — this ADR, AGENTS.md's "Public-repo constraints",
  and the `git ls-files` invocation in the script — and only the third one is
  executable. Adding a surface means editing all three.
- **`docs/adr/` is not itself scanned** (only `docs/index.md` is, under `docs/`).
  ADRs are therefore governed by this decision but not enforced by the checker —
  keep names out of them by hand.
- The check was proven to catch by a plant-and-restore test, and on its first
  real run caught three fresh hits concurrent work had just written into
  `AGENTS.md`, `scripts/profile.sh` and an audit probe's comments. Five further
  hits in files under concurrent edit at the time are recorded as a
  remaining-hits list in the archived spec rather than left silent. [unverified]
  — whether those five have since been cleared was not re-audited here.

## Alternatives considered

- **Scrub everything, including git history.** Rejected: it destroys the
  historical record and the evidence-bearing provenance comments, and history
  rewriting is a separate, much larger decision with its own blast radius.
- **Keep nothing private — accept the names.** Rejected: the concern is
  discoverability and association on surfaces people actually read and search.
- **Make the repo private.** Rejected implicitly: the repo being public is
  load-bearing elsewhere (it is why the private wheel and its skill are
  gitignored and installed conditionally, so a clone without them still builds).
  [unverified] — no record found of this being weighed explicitly.
- **A committed name list.** Rejected: it publishes the very strings being
  checked for.
- **A one-time cleanup with no lint.** Rejected on measured growth: 4 new
  occurrences in 6 days.

## Locked by

- `bash scripts/private-names-check.sh` — the check itself; also the ninth line
  of `just test-offline`.
- `.gitignore` — the `.private-names.local` entry keeps the list untracked.
