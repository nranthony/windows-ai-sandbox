# 0007 — genericise profile/client identifiers in a public repo

**Status:** Scope decided and applied 2026-08-24. Raised 2026-08-18 while
rewriting the README's restart section, which had been written against the
live fleet by name.
**Size:** small, but it needed one scope decision before it was mechanical.

## Scope decision (owner-confirmed, 2026-08-24)

**Searchable, not "present at all."** The concern is discoverability and
association on high-visibility surfaces — README, scripts, shipped templates,
top-level docs — not every occurrence anywhere in the tree. Rationale:

- Archived narrative (`docs/_archive/`), RFCs (`docs/rfcs/`), and `work/*/`
  are historical record. Rewriting them to look tidier is a worse outcome
  than the disclosure — they document what actually happened and when.
- Evidence-bearing uses are kept on purpose: `proxy/allowed_domains.txt`'s
  provenance comments name which account a workspace ID belongs to and why
  one entry was UNVERIFIED. The name there **is** the checkable evidence —
  anonymising it would turn a falsifiable claim into an unfalsifiable one,
  the same class of loss as replacing a content diff with a hash.
  `sandbox-hardening-package.md`'s "verified inside the `<name>` profile"
  line is the one place this reasoning applied to a *user-facing* doc, so it
  was rewritten instead to keep the checkable ID
  (`90141295179`) without the name — the ID was already established
  non-secret.
- No git-history rewriting: the names are in past commits; that is a
  different and much larger decision, not part of this one.

This also promotes the "Non-goals" line about a lint check: occurrences grew
4 in 6 days between the original 9-file audit and the 2026-08-24 re-audit
below, entirely through ordinary agent work adding new comments that happened
to name a client. A one-time cleanup does not hold under that growth rate, so
`scripts/private-names-check.sh` was added — case-insensitive, offline, wired
into `just test-offline` — scanning the same high-visibility-surface list
this decision defines. See [AGENTS.md](../../AGENTS.md) "Public-repo
constraints" for the standing paragraph.

## Why

This repo is **public** (that fact is load-bearing elsewhere — it is why the
`myclickup` wheel and its skill are gitignored). Real profile names are also real
client and project names, and 9 tracked files carry them.

The README is already fixed: two `just down <name> && …` lines added earlier that
day were reworded to `just list` + `just down <profile>`, which is both generic and
better documentation. This item is the rest of the tree.

## The finding

The original grep above was case-sensitive and missed one hit (the
`CLICKUP_TOKEN_THERAPOD` example in `sandbox_templates/common/secrets.env.template`,
all-caps). A 2026-08-24 re-audit with `git ls-files | xargs grep -clEi
'fluidmomenta|therapod'` found 13 files / 27 hits — corrected table below.
The `work/0005-cross-repo-skill-pipeline/notes.md` citation has since moved to
`docs/_archive/cross-repo-skill-pipeline-notes.md:130` (0005 exited per
work/README.md and its durable content archived).

| File | Hits | Kind |
|---|---|---|
| `proxy/allowed_domains.txt` | 4 | provenance comments beside workspace IDs — **kept** |
| `docs/_archive/dependency-guardrails-plan.md` | 4 | archived narrative — **kept** |
| `scripts/code-attach.sh` | 4 | usage examples in the header — **fixed** |
| `docs/dependency-guardrails-handoff.md` | 3 | narrative — **kept** (not a high-visibility surface) |
| `docs/rfcs/04-portable-guardrails-outside-sandbox.md` | 2 | narrative — **kept** |
| `sandbox-hardening-package.md` | 1 | "verified inside the <name> profile with …" — **rewritten**, ID kept |
| `sandbox_templates/common/secrets.env.template` | 1 | `CLICKUP_TOKEN_THERAPOD` example (case-insensitive catch) — **fixed** |
| `work/0003-repo-scan-audit/plan.md` | 1 | narrative — **kept** |
| `docs/_archive/cross-repo-skill-pipeline-notes.md` | 1 | archived narrative (moved from 0005/notes.md) — **kept** |
| `.gitignore` | 1 | ignored filenames naming two clients — **fixed**, broader pattern |

That is 22 of the 27 audited hits. The remaining 5 belong to files under active,
concurrent edit by other in-flight work (`AGENTS.md`, `scripts/profile.sh`,
`scripts/audit/probes/settings.py`, `docs/permissions-model.md`,
`work/0010-antigravity-permissions-and-hooks/spec.md`,
`work/0011-one-policy-convergence-across-agents/{plan,spec}.md`) and were out of
bounds for this pass; several are new since the 08-24 audit (occurrences grew 4
in 6 days — see the scope decision above) and are exactly the kind of thing
`scripts/private-names-check.sh` now catches going forward. `AGENTS.md` and
`scripts/` are high-visibility surfaces per the scope decision, so those hits
are real findings for whoever next touches those files, not exempted by kind —
they just weren't this task's to fix given the concurrency lock.

`github.com/nranthony/macolima` in the README is a deliberate public attribution
and is **not** in scope.

## What actually needed deciding

**This was not a find-and-replace, and treating it as one would have been the
failure mode.** Roughly half the hits were *evidence*: "verified inside the
`<name>` profile with `myclickup spaces --live --workspace <id>`" is checkable
precisely because it names the profile. Anonymising it turns a verifiable
claim into an unfalsifiable one — the same class of loss as replacing a
content diff with a hash.

The decision to pin was: **how public is "public" here** — is the concern that
names are *searchable* (in which case executable and user-facing files matter
and archived prose does not), or that they appear *at all*? Resolved above:
searchable. Executable/user-facing/high-visibility surfaces are in scope;
archived narrative, RFCs, work items, and evidence-bearing uses are not.

## Applied scope

**Done** — genericised; nothing of value was lost:
- `scripts/code-attach.sh` — header usage examples → `<profile>` / `<repo>`
- `.gitignore` — the ignored filenames named two clients; replaced with a
  broader `*-setup.md` pattern that covers both without naming either
- `sandbox_templates/common/secrets.env.template:50` — `CLICKUP_TOKEN_THERAPOD`
  example → `CLICKUP_TOKEN_ACME` (the case-insensitive catch; ships into every
  profile)

**Done, rewritten to keep the evidence without the name:**
- `sandbox-hardening-package.md` — "verified in a profile whose workspace pin
  is `90141295179`" preserves checkability; the ID is already deemed non-secret

**Left** — the name is the evidence, and these are not high-visibility surfaces:
- `proxy/allowed_domains.txt` — the comments explain which workspace ID belongs
  to what and why one was UNVERIFIED. That reasoning is why the entries are
  auditable. Note the file already argues that workspace IDs are configuration,
  not secrets (myclickup ADR-0005) — but that argument covers the **IDs**, not
  the org names beside them, so keeping the names here is a judgement call, not
  a settled one; it is the deliberate exclusion `private-names-check.sh`'s
  header names explicitly.
- `docs/_archive/`, `docs/rfcs/`, `work/*/`, and `docs/*.md` outside
  `docs/index.md` (e.g. `docs/dependency-guardrails-handoff.md`) — historical
  or narrative records; rewriting them to look tidier is worse than the
  disclosure, and they are not the surfaces `private-names-check.sh` scans.

## Non-goals

- Renaming the actual profiles or their host state. Nothing here touches
  `~/.ai-sandbox/profiles/` or `~/repo/`.
- Rewriting git history. The names are in past commits; if that matters, it is a
  different and much larger decision.

## Lint check (promoted into scope 2026-08-24)

Originally a non-goal — "worth considering after the scope decision" — but the
owner promoted it once the audit showed occurrences growing 4 in 6 days: a
one-time cleanup does not hold at that rate. `scripts/private-names-check.sh`
scans the same high-visibility-surface list this spec defines, case-
insensitively, reading the name list from a gitignored `.private-names.local`
(the repo's existing pointer-file convention — never committed, since the
names living in the tracked tree is exactly what the check exists to catch).
Two states only: unconfigured → loud `[SKIP]`, exit 0; configured → scan, exit
0/1. Wired into `just test-offline`. See `AGENTS.md` "Public-repo constraints".

## Exit criteria — met

- Scope decision recorded (above), with rationale. **Met.**
- The "Do" tier applied. **Met** (see "Applied scope").
- `git ls-files | xargs grep -clEi 'fluidmomenta|therapod'` returns only hits
  that were deliberately kept, **except** for 5 hits in files under active,
  concurrent edit by other in-flight work at the time of this pass
  (`AGENTS.md`, `scripts/profile.sh`, `scripts/audit/probes/settings.py`,
  `docs/permissions-model.md`, `work/0010/spec.md`, `work/0011/{plan,spec}.md`)
  — out of bounds for this pass; several are new since the 08-24 audit and are
  exactly what the lint check now exists to catch going forward. **Not fully
  met**; tracked as a remaining-hits list in this spec rather than left silent.
- Case-insensitive check exists (`scripts/private-names-check.sh`), offline,
  wired into `just test-offline`. **Met.**
- One paragraph into `AGENTS.md` under "Public-repo constraints". **Met.**

This folder exits per [work/README.md](../README.md) once the remaining 5
concurrent-work hits are resolved by whoever lands that work — nothing durable
lives only here beyond what is now in `AGENTS.md` and this spec's own record.
