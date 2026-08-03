# Host-side skill slot — `make-plan` and `wrap-up` are container-only

**Status:** Not started. Parked deliberately — raised while restructuring for
[ADR-0001](../../docs/adr/0001-provenance-tiers.md), and **not part of the dependency
guardrails thread** ([`work/0001`](../../docs/_archive/dependency-guardrails-plan.md)).

**Exit rule:** delete this folder, or move to `work/archive/`, when the work merges.

---

## Problem

Commit `1151235` vendored `make-plan` and `wrap-up` from `agentic-conventions` into
`sandbox_templates/skills/`. That tree is the **container-side** seeding path:
`profile.sh`'s `ensure_state` copies it into each profile's state dir, so the skills reach
agents running *inside* a sandbox profile.

The **host** agent — working in this repo, on this checkout — cannot reach them.

**Confirmed:**

- This repo has no `.claude/skills/`. `.claude/` contained only the gitignored
  `settings.local.json` before ADR-0001 added `settings.json`.
- `.agents/skills/` holds three host-side guides (`profile-lifecycle.md`,
  `security-audit.md`, `squid-management.md`), but the conventions scaffold states plainly
  that **Claude Code does not read `.agents/skills/`**. They work today only because
  `AGENTS.md` links them as ordinary markdown — they are runbooks, not invocable skills.
  No `/profile-lifecycle` invocation exists; the agent reads the file when the index
  points it there.
- Consequence: `/make-plan` and `/wrap-up` are not invocable in this repo, which is the
  repo that ships them.

## Why it was parked

It surfaced during a restructure whose subject was the dependency-guardrail document set.
Standing up a host-side skill slot is a direction-setting change to how this repo is
navigated — the `wrap-up` skill's own §0 says adding opt-in machinery "deserves its own
conversation," never a cleanup side-effect. Same reasoning applies here.

## Decisions needed

1. **Does the host get `.claude/skills/`?** Options:
   - **a. Add `.claude/skills/`**, vendoring `make-plan` + `wrap-up` a second time. Costs a
     duplicate copy of each skill in the tree and a second sync destination.
   - **b. Container-only, by design.** Accept that host-side planning is done by hand
     (as it was for ADR-0001) and that `.agents/skills/` stays index-linked runbooks.
   - **c. Host-side only for shared skills**, keeping `sandbox_templates/skills/` for the
     sandbox-native ones (`audit-sandbox`, `web-read`) — but those are precisely the ones
     profiles need, so this likely inverts the requirement.
2. **If (a): does `sync-skills-from-conventions.sh` write both destinations?**
   It currently resolves one destination tree. Two destinations means either a flag, a loop
   over a destination list, or a post-sync copy step. **Confirmed:** the script is held to
   the bash-3.2/POSIX-awk subset for macolima portability — whatever is added must stay in
   that subset.
3. **Does `UPSTREAM.md` need to track per-destination revs**, or is one rev per skill
   sufficient when both copies come from the same sync run?
4. **Does macolima need the same treatment**, and does that change the answer to (1)?

## Investigation to do first

- Read `scripts/sync-skills-from-conventions.sh` in full — destination resolution, the
  dry-run path, and how `UPSTREAM.md` is generated.
- Check whether `.claude/skills/` would be picked up given this repo's settings, and
  whether a skill in both `sandbox_templates/skills/` and `.claude/skills/` causes any
  collision for an agent running inside a profile whose workspace *is* this repo.
- Confirm against the sibling repo (golden rule 3) before changing the sync script.

## Non-goals

- Changing what the vendored skills contain. They are upstream's; edits go upstream.
- Anything about `.agents/skills/` content — the three host guides are working as
  index-linked docs and are not in question here.
