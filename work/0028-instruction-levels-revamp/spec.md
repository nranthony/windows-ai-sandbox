# 0028 — Instruction levels: inspect every layer an agent reads, and put each rule at the right one

**Status: Draft** — opened 2026-09-10. Triggered by a single missing rule (gloss
before cite, below) but scoped to the whole stack, because the inventory taken
while finding that gap showed the same shape everywhere: rules present at one
level, absent at the next, and at least one level carrying content that belongs
somewhere else.

**Cross-refs:** the gloss-before-cite decision and its shorthand extension
(agentic-conventions ADR-0010, ADR-0011); the notice-drift item
([0025](../0025-notice-says-registries-closed-and-pypi-is-open/spec.md)) — the
same class of defect, one level down; the agent-notice test
(`scripts/agent-notice.test.sh`) — the one existing lock on any of these files.

---

## 1. The trigger, and why it is not the whole problem

The owner asked whether any instruction file says "name the thing in plain
language, then the code" — never a bare `ADR-0010` or `D1`. The rule exists,
is well defined, and was decided twice upstream (identifiers 2026-08-12,
in-flight shorthand 2026-08-16). It reached exactly the repos that ran
`apply-conventions` with the template that carries it. It never reached this
repo, the depot channel, myclickup, the global instructions, or the notice
deployed into every profile. The session that noticed the gap had itself just
written bare codes in a reply.

That is a **placement** failure, not a **definition** failure. A rule about how
the *reader* likes to be written to was delivered by a *repo-level* vehicle, so
it arrived only where someone happened to run the vehicle.

## 2. The levels, as measured 2026-09-10

Seven files an agent may read before acting, on this machine. Size and whether
four representative rules are present (`grep -ci`; a count, not a judgement):

| Level | File | Lines | gloss | git push | tests | directness |
|---|---|---|---|---|---|---|
| user (host) | `~/.claude/CLAUDE.md` | 28 | 0 | 1 | 3 | 3 |
| profile (container) | `sandbox_templates/common/agent-notice.md` → every `claude-home/CLAUDE.md` | 188 | 0 | 1 | 3 | 4 |
| repo, this one | `AGENTS.md` | **457** | 0 | 0 | 18 | 8 |
| repo, channel | `depot/AGENTS.md` | 118 | 0 | 0 | 1 | 3 |
| repo, member | `depot/myclickup/AGENTS.md` | 89 | 0 | 0 | 3 | 2 |
| repo, member | `depot/paperbridge/AGENTS.md` | 104 | 1 | 0 | 3 | 1 |
| repo, source of the template | `depot/agentic-conventions/AGENTS.md` | 83 | 3 | 0 | 0 | 3 |
| template | `apply-conventions/templates/AGENTS.md` (vendored here as the myconv skill) | 69 | 1 | 0 | — | — |

Three observations the numbers support:

1. **No rule is present at every level**, including the ones the owner treats
   as universal (never push unasked; run the tests before claiming done).
2. **This repo's `AGENTS.md` is five to six times the size of any other.** Most
   of it is per-suite lore ("edits to X require `bash Y` (N/N) — and here is why
   assertion Z exists") that is true and valuable but is *reference*, not
   *instruction*. It is auto-loaded into every session on this repo whether or
   not the session touches those files.
3. **The live profile notice differs from its template** (190 vs 188 lines in
   the `nranthony` profile). Possibly a deliberate header from
   `sync-agent-notice.sh`; unverified, and exactly the kind of drift 0025 found
   in content rather than length. To be checked, not assumed, in the plan.

Two levels exist that the table cannot see and the plan must not forget: the
**macolima** sibling on the Mac, which receives none of the host-level files,
and any **in-container repo** a profile opens that never ran
`apply-conventions`, which receives only the notice.

## 3. The placement principle this item should settle

A rule belongs at the level of the thing it is *about*:

| The rule is about | Level | Vehicle | Reaches |
|---|---|---|---|
| the reader — how the owner wants to be written to, what they will and will not tolerate unasked (gloss, directness, push back, no unsolicited summaries) | **user** | `~/.claude/CLAUDE.md` on the host; the **agent notice** in containers, because it is the user level's only route inside the boundary | every session on this machine and in every profile |
| the boundary — what the sandbox denies and why a denial is a human step | **profile** | the agent notice | every container |
| a repo — its map, its gates, its high-risk paths | **repo** | `AGENTS.md`, via the template | that repo, anywhere it is checked out |
| a cross-repo convention shared by a set of repos | **template** | `apply-conventions/templates/AGENTS.md` | every repo that applies it, on any machine |

So the answer to "if I want it everywhere, should it be global?" is **yes, with
one correction**: on this machine "global" is two files, not one. The host-level
`~/.claude/CLAUDE.md` does not enter a container; the notice is the in-container
equivalent, and the two are today maintained with no reference to each other.
A user-level rule needs both, and the plan should decide whether that means the
notice *embeds* the user file, *references* it, or both are generated from one
source.

The template keeps a copy too, deliberately: a rule the owner wants from every
agent should also hold for a collaborator's agent in a shared repo, and the
template is the only vehicle that crosses machines and accounts.

## 4. What the plan must do

1. **Verify the notice drift** (§2 point 3) before anything else. If it is
   real, it is a 0025-class defect and gets fixed on that item's terms.
2. **Inventory every rule across the eight files** as a matrix: rule × level,
   with the file and line where each lives. Generated, not transcribed; the
   inventory script stays in the repo so it can be re-run.
3. **Assign each rule a level** by §3. Expect three outcomes per rule: it is
   already right; it must be **added** somewhere (gloss to user + notice +
   this repo); it must be **moved** (most of this repo's per-suite lore to a
   linked reference doc, leaving a one-line pointer per suite).
4. **Decide the user ↔ notice relationship** (D2 below) and implement it.
5. **Re-apply the template** to the repos that lack the template line — this
   one, the channel, myclickup — through `apply-conventions --audit` first so
   the gap is measured rather than assumed, then apply.
6. **Lock what can be locked.** The gloss rule is unlintable by design and stays
   advice. But *presence* is lintable: a test that every user-level rule
   appears in both user-level files, and that the template's Golden rules
   appear in every consumer `AGENTS.md`, can run offline alongside
   `agent-notice.test.sh`.
7. **Ferry the cross-repo half.** Edits to the template and to member
   `AGENTS.md` files are depot-side; the admin profile
   ([0027](../0027-admin-profile/spec.md)) would make this the last ferried
   round, but this item does not wait for it.

## 5. Decision gates

| # | Question | Recommendation |
|---|---|---|
| D1 | Is the user-level rule set defined once and rendered into both `~/.claude/CLAUDE.md` and the notice, or maintained as two files with a presence test? | **Two files plus a presence test.** The notice already has a test and a deploy script; generating it from a private host file couples a public template to a private one |
| D2 | Does this repo's `AGENTS.md` shrink by moving per-suite lore to a reference doc? | **Yes.** Target: the golden rules, the security-sensitive file list, and one line per suite naming its test command and count; the "why assertion Z exists" paragraphs move to `docs/test-suites.md` and are linked. The content is kept verbatim, only its auto-load status changes |
| D3 | Does the gloss rule go into the template's Golden rules only, or also into the blueprint? | Template only — already decided upstream (their ADR-0010 §6); do not reopen |
| D4 | Does macolima get the user-level rules by hand or by a synced file? | By hand for now, as a named step in the plan; a synced file is a macolima item |

## 6. Out of scope

- Rewriting the upstream ADRs or the template's wording. The rule is right;
  its delivery is what this item fixes.
- The permissions and hook policy templates. Those are enforcement, not
  instruction, and have their own suites.

## 7. Exit rule

Merges when: the rule × level matrix exists and is generated; every user-level
rule is present in both user-level files and a presence test proves it; this
repo's `AGENTS.md` carries the template's Golden rules and is materially
shorter with nothing lost; the channel and myclickup have been audited and the
ferry delivered; and the notice drift is either shown to be benign or fixed.
Then this folder archives to `docs/_archive/`.
