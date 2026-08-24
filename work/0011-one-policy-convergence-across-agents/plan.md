# 0011 — Plan: one policy convergence across every code agent

Read [`spec.md`](spec.md) first — §1 is measured, and F2/F3 correct two
assumptions the work was requested under.

Small on purpose. `up`, `recreate`, `rebuild` and `wipe` already call
`ensure_state`; the mechanism to generalise already exists and is already tested.
Most of the risk is in what must NOT change.

---

## Phase 1 — one convergence function

### T01 — `converge_agent_policy` in `profile.sh`

Generalise the body of `converge_antigravity` to take a descriptor:

```
converge_agent_policy <template> <dest> <owned-key>...
```

Merges the owned keys from the template into `dest`, preserves every other key,
writes only when the result differs, and writes atomically (`.tmp` + `os.replace`,
as today). Refuses to touch a `dest` that exists but is not valid JSON — a corrupt
policy file is the agent's to report, not ours to silently replace.

Descriptors live in one table near the function, not scattered through
`ensure_state`, so adding opencode is one row.

### T00 — PREREQUISITE: settle the myclickup promotions (spec F7)

Blocking, because T02 reverts them the moment it lands. The owner wants
`Bash(myclickup comment:*)`, `set-status` and `update` kept, and no repo-local
file can hold them while the template lists them under `ask`.

Move exactly those three from `ask` to `allow` in **both** templates (the parity
suite enforces an exact match), and amend the "reads yes, writes prompt" section
of `docs/permissions-model.md` to record what changed and why. This is a
security widening — ClickUp writes become unprompted in every profile — so it
needs its own `SECURITY IMPACT` line and explicit owner sign-off in the commit.

**Owner sign-off 2026-08-24.** Confirmed by the owner on the day; recorded here
and in the commit message. Implemented: the three moved from `ask` to `allow` in
both templates, the `_myclickup_note`/`_ask_note`/`_comment_ask` blocks rewritten
to say what changed and why, and `docs/permissions-model.md`'s "reads yes, writes
prompt" section corrected — including the stale "19 commands: 13 reads and 6
writes … every write hits the `defaultMode: auto` prompt" sentence, which was
wrong on the count (real surface 28/17/11 as of 0.6.0) and on the mechanism (the
operative control is the `_ask_note` rule set; absence alone does not prompt).

### T02 — Claude joins the convergence

Replace the `[[ ! -f ... ]]` create-only guard (`profile.sh:575`) with
`converge_agent_policy claude-settings.json claude-home/settings.json env hooks permissions sandbox`.

Mode is **overwrite** (spec §2), so the work is the loud-but-not-noisy part:

1. Write the dropped non-template keys to `claude-home/settings.discarded.json`
   before overwriting — **including the content diff of any owned key that
   differs from the template**. Top-level capture alone misses a change
   *inside* an owned key: the F7 `permissions` promotion would be reverted
   without record otherwise (spec §2 requirement 4).
2. Warn **only when that set differs from the previous run** — an unconditional
   warning fires on every `up` forever, because Claude rewrites `model` and
   `effortLevel` every session, and a warning that always fires is not read.
   The owned-key diffs from (1) participate in this comparison.
3. The message names the discard file, not a JSON blob to copy out of scrollback.
4. `skipAutoPermissionPrompt` is user-or-managed scope (F6): **decided** — the
   overwrite carries a preserve list for it (a key with nowhere else to live is
   merged, per the spec's own mode rule).

   **Owner decision 2026-08-24, revising this item:** the preserve list is
   **four** keys, not one — `skipAutoPermissionPrompt`, `model`, `effortLevel`,
   `agentPushNotifEnabled`. Re-picking a model and an effort level after every
   `up` is friction the sandbox gains nothing from; none of the three carries a
   security opinion.

   Preserve has two halves. A live value survives; a live file that **lacks**
   the key takes the **template default**, which is why
   `sandbox_templates/claude/claude-settings.json` now carries `"model": "opus"`,
   `"effortLevel": "medium"`, `"agentPushNotifEnabled": false`. Without the
   second half a fresh profile — and every profile the pre-decision converge had
   already stripped — stays unset forever.

   The four are **preserved, not owned**: tier-1 `check_agent_policy_sync`
   compares the owned keys only, and tier-2's `template_diff` now strips the
   preference keys from **both** sides (stripping only `live` would have made
   the new template defaults read as DRIFT on every profile where the operator
   picked something else).

   Opt-out: `profile.sh <p> converge --defaults` / `just converge <p> --defaults`
   overwrites all four with the template defaults instead, capturing what it
   replaced under a `preference_resets` key in `settings.discarded.json`.
   `skipAutoPermissionPrompt` has no template default, so `--defaults` leaves it
   alone rather than dropping a key no repo file can hold.

   `skipWorkflowUsageWarning` goes to the discard file like any other unowned key.

Also fix `USER_CUSTOMIZATION_KEYS` at `scripts/audit/probes/settings.py:30` — it
lists three of the six observed keys, and the 2026-08-24 audits show the
consequence live: `template_diff` reports DRIFT on all three profiles today
(`agentPushNotifEnabled`; plus `permissions` on fluidmomenta).

### T03 — `converge_antigravity` becomes a descriptor

Two owned keys plus the whole-file `hooks.json`. Behaviour must be
bit-identical to today; the 0010 convergence locks stay green unchanged, which is
the check that the generalisation did not quietly alter it.

### T04 — `just converge <profile>`, and delete the three

`profile.sh <p> converge` runs every agent descriptor + `converge_skills` +
`sync-agent-notice`, touching no container. When the profile's container is
running, it prints the same "restart the agent inside the container to pick up"
instruction every `reset-*` branch ends with today
(`profile.sh:1431/:1442/:1454`) — converging under a live session is a
lost-update race in both directions (spec §2), and the restart line is the
contract that closes it. `reset-settings`, `reset-skills`,
`reset-antigravity` are removed from `profile.sh`, the `justfile`, and the usage
header. No aliases — the repo's standing rule is no compatibility shims, and the
whole point is to stop having three commands with three semantics.

Breaking change; say so in the commit body and in **every** doc and string that
names the removed commands — the sweep is larger than the obvious docs:
`README`, `.agents/skills/profile-lifecycle.md`, `AGENTS.md` quick reference,
the two downstream handoffs ADR-0005 mentions, `verify-sandbox.sh`'s
remediation strings (:177/:190/:192/:251/:254 — printed *from inside
containers*), the DEPLOYMENT paragraph in the shipped template's
`_myclickup_note`, `init-profile-state.sh:82-83`'s create-only note,
`justfile:176-187`, `profile.sh` header (:29-33) and help (:1607),
`docs/extending-a-profile.md:103/:163`, `docs/sandbox-design-notes.md:30`,
`docs/deny-destructive-hook-plan.md:29`, and ADR-0006:123.

---

## Phase 2 — detectors

### T05 — tier-1 drift check for the Claude policy

Nothing today reports that a profile's Claude policy is behind its template.
Assert the live file matches the template **on the owned keys only** — comparing
whole files would fire on `model` and be trained away as noise.

### T06 — verify the tier-2 `template_diff` after T02's constant fix

An earlier draft said the probe's staged path exists in only one profile and
the check silently does not run. **Measured 2026-08-24: wrong on both halves.**
`profile.sh:1395` runs `stage-audit-package.sh` on every `audit`, all three
profiles carry the staged template md5-identical to the source, and a missing
file reports UNKNOWN, never OK. The real defect is the stale
`USER_CUSTOMIZATION_KEYS` — the 2026-08-24 audit JSONs report DRIFT on all
three profiles (`agentPushNotifEnabled`; plus `permissions` on fluidmomenta,
the F7 promotion caught live). T02 fixes the constant; T06 is the check on the
check: after T02, `template_diff` goes OK on a converged profile and still
reports DRIFT on a hand-edited one (prove the second by editing, not by
reading the code).

### T07 — extend the offline suite

`antigravity-parity.test.sh` becomes the policy-convergence suite for both
agents (rename to `agent-policy.test.sh`):

- owned keys are written; **every other key survives** — one assertion per agent,
  using the real runtime keys from spec F4;
- idempotent on a second run;
- bootstraps a profile where the agent has never run;
- still never a directory mirror (the four 0010 locks, unchanged);
- the existing deny-list parity checks, unchanged;
- remove the dead `//`-stripping and the comment claiming the two templates
  differ in comment style — measured, they do not.

---

## Phase 3 — documentation, and the correction that matters most

### T08 — write down the tighten-only rule

`docs/permissions-model.md` gains the per-agent override table and, prominently,
spec F2: **a repo-local file cannot re-allow what the sandbox globally denies.**
Deny wins from any scope. Anyone who reaches for a repo-local file to unblock
`curl` needs to find that sentence before they spend an afternoon on it.

Also record that `agy` has no in-repo permission surface at all (F3), so the
pattern is Claude-only — and that project-scope `allow` rules need folder trust
while `deny`/`ask` apply immediately.

### T09 — the rest of the docs

`ARCHITECTURE.md` (state layout: which keys are sandbox-owned per agent),
`AGENTS.md` (the new suite contract, the removed commands), `README`,
`.agents/skills/profile-lifecycle.md` (`converge`, and that policy no longer
lags), and 0009's comparison table where it says `agy` has no permissions.

### T10 — record the decision

ADR-0005 established "templates are the source of truth" for skills. This
extends it to every agent's policy and adds the merge-owned-keys rule. Amend
ADR-0005 or add a short ADR-0007 pointing at it — the append-only rule means
amend by supersession, not edit.

---

## What this plan deliberately does not do

- **A per-repo override for `agy`.** No such file exists (F3). If it is ever
  wanted, the honest route is the shared hook reading a
  `<repo>/.agents/sandbox-policy.json` of *additional denies only* — enforced by
  the engine we control, structurally unable to loosen. Separate work item,
  speculative until asked for.
- **Wiring opencode or codex.** The descriptor slot is left ready; opencode still
  needs its own Phase 0 (0009), including whether it has a per-repo surface and
  how last-match-wins globs interact with a converged global file.
- **Touching the hook script.** The engine reaches containers through the image
  and that does not change: policy converges on `up`, the engine still needs
  `build` + recreate. Worth stating plainly in T09 because it is the other half
  of the confusion that started this.
