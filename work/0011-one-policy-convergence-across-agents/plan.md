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

### T02 — Claude joins the convergence

Replace the `[[ ! -f ... ]]` create-only guard (`profile.sh:575`) with
`converge_agent_policy claude-settings.json claude-home/settings.json env hooks permissions sandbox`.

Mode is **overwrite** (spec §2), so the work is the loud-but-not-noisy part:

1. Write the dropped non-template keys to `claude-home/settings.discarded.json`
   before overwriting.
2. Warn **only when that set differs from the previous run** — an unconditional
   warning fires on every `up` forever, because Claude rewrites `model` and
   `effortLevel` every session, and a warning that always fires is not read.
3. The message names the discard file, not a JSON blob to copy out of scrollback.
4. `skipAutoPermissionPrompt` is user-or-managed scope (F6): either the template
   owns it, or the message says it cannot go per-repo. Do not advise something
   that will not work.

Also fix `USER_CUSTOMIZATION_KEYS` at `scripts/audit/probes/settings.py:30` — it
lists three of the six observed keys and has been stale for months.

### T03 — `converge_antigravity` becomes a descriptor

Two owned keys plus the whole-file `hooks.json`. Behaviour must be
bit-identical to today; the 0010 convergence locks stay green unchanged, which is
the check that the generalisation did not quietly alter it.

### T04 — `just converge <profile>`, and delete the three

`profile.sh <p> converge` runs every agent descriptor + `converge_skills` +
`sync-agent-notice`, touching no container. `reset-settings`, `reset-skills`,
`reset-antigravity` are removed from `profile.sh`, the `justfile`, and the usage
header. No aliases — the repo's standing rule is no compatibility shims, and the
whole point is to stop having three commands with three semantics.

Breaking change; say so in the commit body and in the docs that name them
(`README`, `.agents/skills/profile-lifecycle.md`, `AGENTS.md` quick reference,
and the two downstream handoffs ADR-0005 mentions).

---

## Phase 2 — detectors

### T05 — tier-1 drift check for the Claude policy

Nothing today reports that a profile's Claude policy is behind its template.
Assert the live file matches the template **on the owned keys only** — comparing
whole files would fire on `model` and be trained away as noise.

### T06 — fix or retire the tier-2 `template_diff`

`scripts/audit/probes/settings.py` reads
`/workspace/temp_audit_package/config/claude-settings.json`. That path exists in
one profile, so for every other profile the check silently does not run and the
probe still reports OK. Either stage the template where the probe can always see
it, or delete the check and let T05 own drift. A check that quietly does not run
is worse than no check.

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
