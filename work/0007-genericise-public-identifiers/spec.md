# 0007 — genericise profile/client identifiers in a public repo

**Status:** Not started. Raised 2026-08-18 while rewriting the README's restart
section, which had been written against the live fleet by name.
**Size:** small, but it needs one scope decision before it is mechanical.

## Why

This repo is **public** (that fact is load-bearing elsewhere — it is why the
`myclickup` wheel and its skill are gitignored). Real profile names are also real
client and project names, and 9 tracked files carry them.

The README is already fixed: two `just down <name> && …` lines added earlier that
day were reworded to `just list` + `just down <profile>`, which is both generic and
better documentation. This item is the rest of the tree.

## The finding

`git ls-files | xargs grep -cE 'fluidmomenta|therapod'` — 9 files, 21 hits:

| File | Hits | Kind |
|---|---|---|
| `scripts/code-attach.sh` | 4 | usage examples in the header |
| `proxy/allowed_domains.txt` | 4 | provenance comments beside workspace IDs |
| `docs/_archive/dependency-guardrails-plan.md` | 4 | archived narrative |
| `docs/dependency-guardrails-handoff.md` | 3 | narrative |
| `docs/rfcs/04-portable-guardrails-outside-sandbox.md` | 2 | narrative |
| `sandbox-hardening-package.md` | 1 | "verified inside the <name> profile with …" |
| `work/0003-repo-scan-audit/plan.md` | 1 | narrative |
| `work/0005-cross-repo-skill-pipeline/notes.md` | 1 | narrative |
| `.gitignore` | 1 | an ignored filename that names a client |

`github.com/nranthony/macolima` in the README is a deliberate public attribution
and is **not** in scope.

## What actually needs deciding

**This is not a find-and-replace, and treating it as one is the failure mode.**
Roughly half the hits are *evidence*: "verified inside the `<name>` profile with
`myclickup spaces --live --workspace <id>`" is checkable precisely because it names
the profile. Anonymising it turns a verifiable claim into an unfalsifiable one —
the same class of loss as replacing a content diff with a hash.

The decision to pin: **how public is "public" here** — is the concern that names are
*searchable* (in which case executable and user-facing files matter and archived
prose does not), or that they appear *at all*?

## Proposed scope, pending that decision

**Do** — genericise; nothing of value is lost:
- `scripts/code-attach.sh` — header usage examples → `<profile>` / `<repo>`
- `.gitignore:14` — the ignored path names a client; a broader pattern covers it

**Consider** — rewrite to keep the evidence without the name:
- `sandbox-hardening-package.md` — "verified in a profile whose workspace pin is
  `<id>`" preserves checkability; the ID is already deemed non-secret

**Leave** — the name is the evidence, and these are not user-facing:
- `proxy/allowed_domains.txt` — the comments explain which workspace ID belongs to
  what and why one was UNVERIFIED. That reasoning is why the entries are auditable.
  Note the file already argues that workspace IDs are configuration, not secrets
  (myclickup ADR-0005) — but that argument covers the **IDs**, not the org names
  beside them, so this one is a genuine judgement call rather than settled.
- `docs/_archive/`, `docs/rfcs/`, `work/*/` — historical records; rewriting history
  to look tidier is worse than the disclosure.

## Non-goals

- Renaming the actual profiles or their host state. Nothing here touches
  `~/.ai-sandbox/profiles/` or `~/repo/`.
- Rewriting git history. The names are in past commits; if that matters, it is a
  different and much larger decision.
- Adding a lint/CI check for new occurrences. Worth considering **after** the scope
  decision, not as part of it.

## Exit criteria

The scope decision is recorded, the "Do" tier is applied, and `git ls-files | xargs
grep` returns only hits that were deliberately kept. Then this folder exits per
[work/README.md](../README.md) — nothing durable lives only here, so delete rather
than archive unless the scope decision itself is worth keeping (it probably is:
one paragraph into `AGENTS.md` under the public-repo constraints).
