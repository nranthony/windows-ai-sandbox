# ADR-0007 — Policy templates are the source of truth for EVERY agent

- **Status:** Accepted
- **Date:** 2026-08-24
- **Supersedes:** [ADR-0005](0005-skill-templates-are-source-of-truth.md) — which
  established the principle for **skills** only. ADR-0005 stays as written
  (append-only); everything it says about the skills tree still holds, and this
  ADR extends the principle to every agent's policy file and adds the write-mode
  rule ADR-0005 did not need.
- **Also amends:** [ADR-0006](0006-antigravity-is-two-layer-like-claude.md) in one
  respect only — every `reset-antigravity` it names is now
  `scripts/profile.sh <p> converge`, and the suite it names as
  `scripts/antigravity-parity.test.sh` is now `scripts/agent-policy.test.sh`.
  ADR-0006's substance is unchanged and its file is not edited, per the
  append-only rule.
- **Affects:** `scripts/profile.sh` (`converge_agent_policy`,
  `AGENT_POLICY_DESCRIPTORS`, `ensure_state`, the new `converge` subcommand,
  the removed `reset-settings`/`reset-skills`/`reset-antigravity`),
  `scripts/init-profile-state.sh`, `scripts/verify-sandbox.sh`,
  `scripts/audit/probes/settings.py`, `sandbox_templates/claude/`,
  `sandbox_templates/antigravity/`, the `justfile`, and the sibling `macolima`
  repo when this is ported.

## Context

ADR-0005 fixed create-only seeding for skills. It was never applied to the file
where the argument is strongest. As of 2026-08-23 a template edit reached a
running profile by **three different routes depending on which file you
touched**, and the most security-relevant one was the route that does nothing:

| Edit | Reached a profile via | Automatic on `up`? |
|---|---|---|
| `claude/claude-settings.json` | `reset-settings <p>` only | **no** — seeded create-only |
| `claude/hooks/deny-destructive.sh` | `build` + recreate | no — baked into the image |
| `antigravity/*` | `up` / `recreate` / `rebuild` | yes (ADR-0006) |
| `skills/` | `up` / `recreate` / `rebuild` | yes (ADR-0005) |

So the 96-rule Claude deny list — the single most security-relevant file in the
repo — was the one thing that silently lagged its template, and nothing reported
it. Measured consequence: the `_myclickup_note` block sat in the template and in
none of the three live profiles from 2026-08-10 to 2026-08-15.

Two more agents are expected (opencode, work/0009; codex likely), so the fix had
to be a contract rather than a third bespoke path.

## Decision

**1. Every agent's policy converges to its template on every
`up`/`recreate`/`rebuild`/`wipe`**, through one function
(`converge_agent_policy`) driven by one descriptor table
(`AGENT_POLICY_DESCRIPTORS`). Adding an agent is a row plus a template.

**2. The write mode is chosen per agent by one rule:**

> Overwrite where the agent has somewhere else to put its preferences.
> Merge where it does not.

| Agent | Mode | Why |
|---|---|---|
| Claude Code | **overwrite** | nearly everything it writes back is settable in a repo's `.claude/settings.local.json` |
| Antigravity (`agy`) | **merge** owned keys | no per-repo surface exists at all, and `trustedWorkspaces` is functional state, not a preference |
| opencode (future) | **overwrite** | never writes to `opencode.json`; its prefs live in `tui.json` |

Overwrite buys something merge cannot: the live file **is** the template, so a
future release putting something security-relevant into a key we do not own is
enforced rather than silently preserved. Merge only ever guarantees the owned
keys.

**3. The overwrite must be loud, but not noisy.** Three parts, each answering a
way the previous design would have failed:

- Every key the template does not own is written to
  `claude-home/settings.discarded.json` **before** the overwrite — recoverable
  from disk, not from scrollback.
- The capture includes the **content diff of any owned key that differs**. A
  top-level capture alone misses a change *inside* an owned key, and that is the
  case that actually happened: an in-session "Yes, and don't ask again" lands an
  `allow` rule in `permissions`, which the overwrite reverts. Silent reversion is
  the failure this ADR exists to prevent.
- The warning fires **only when the captured signature changes** — the set of
  dropped key names plus a digest of the owned-key diffs. Claude rewrites `model`
  and `effortLevel` every session, so an unconditional warning fires on every
  `up` forever and stops being read, going quiet in the reader's head exactly
  when a genuinely new key appears.

**4. Four keys ride a preserve list**, and preserve has two halves.

`skipAutoPermissionPrompt` is the mode rule applied per key: user-or-managed
scope, so a repo file cannot hold it, and dropping it leaves the user nowhere to
restore it. `model`, `effortLevel` and `agentPushNotifEnabled` join it by owner
decision (2026-08-24). A repo file *could* hold those three, but making every
operator re-pick a model and an effort level after every `up` is friction the
sandbox gains nothing from — it has no security opinion about any of the three.

The two halves: a **live** value survives convergence, and a live file that
**lacks** the key takes the **template default**. The second half is why
`claude-settings.json` now carries `"model": "opus"`, `"effortLevel": "medium"`
and `"agentPushNotifEnabled": false` — without a template value, "preserve" on a
fresh profile means "leave it unset" forever, and after the first converge under
the original one-key list every profile was in exactly that state.

They are **preserved, not owned**: point 6's detectors compare the owned keys
only, so a live value differing from these defaults is the design working rather
than drift.

`scripts/profile.sh <p> converge --defaults` is the opt-out — it overwrites all
four with the template defaults instead of keeping the live values, and still
writes the discard capture (under `preference_resets`), because a reset the
operator cannot undo is the same silent loss the capture exists to prevent.
`skipAutoPermissionPrompt` has no template default, so `--defaults` leaves it
alone rather than dropping a key nothing else can hold.

Keep the list to keys the sandbox has no security opinion about — every entry is
a hole in "the live file IS the template".

**5. One reset command.** `scripts/profile.sh <p> converge` (`just converge`)
runs exactly what `up` runs, touching no container — with one flag, `--defaults`,
that `up` never passes (point 4).
`reset-settings`, `reset-skills` and `reset-antigravity` are **removed, not
aliased** — the repo does not ship compatibility shims, and three near-identical
commands with three different write semantics is the confusion that produced this
work. **Breaking change.**

When the profile's container is running, `converge` prints the same "restart the
agent inside the container" instruction every `reset-*` branch ended with.
Converging under a live session is a lost-update race in both directions: the
session can write its in-memory settings back over the converge, and the converge
can revert a grant the session just made. The restart line is the contract that
closes it; the discard capture is what bounds the damage when it is ignored.

**6. Two detectors, at two tiers.** Tier-1 `verify` compares the live policy to
its template **on the owned keys only** (whole-file comparison would fire on
`model` and be trained away as noise) — the drift check that did not exist
before. Tier-2 `template_diff` keeps its existing shape; its
`USER_CUSTOMIZATION_KEYS` constant was stale and is fixed, and since point 4 put
defaults in the template it now strips that set from **both** sides of the diff,
not just from the live file — otherwise the template's `"model": "opus"` faces
nothing and reports DRIFT on every profile where the operator picked something
else, which is a false alarm on the ordinary case.

## Consequences

- An in-session grant is **temporary by default**. Making one permanent means
  editing the template and taking the `SECURITY IMPACT` line with it — which is
  exactly what the three `myclickup` write promotions did on the same day. That
  is the intended posture; it is documented in `docs/permissions-model.md` rather
  than left as a surprise.
- Claude's `model`, `effortLevel` and `agentPushNotifEnabled` **survive**
  converge. This ADR was drafted the other way — they reset every converge, were
  captured, and the note here said reversing it would be "a one-word change: add
  the keys to the descriptor's preserve column, deliberately, not reactively".
  The owner made exactly that call on 2026-08-24, before this ADR was published,
  and the trade-off paragraph is recorded here as decided rather than as an open
  option. The deliberate part is the scope: the three are preferences the sandbox
  has no security opinion about, and every one of them is still enforced-by-
  template for anything that *is* owned (`env`, `hooks`, `permissions`,
  `sandbox`) — so point 2's guarantee is unweakened where it matters. What the
  addition does cost is that a live value can now differ from the template
  indefinitely and no detector says so; the answer is that neither detector is
  *supposed* to, and `converge --defaults` exists so the operator can force the
  template back without editing anything.
- The repo-local override story **differs per agent and that is acceptable**.
  Claude has a tighten-only file, `agy` has none, opencode's inverts the ratchet.
  Do not invent a cross-agent override file to paper over it — no agent would
  read it. If per-repo tightening for `agy` is ever wanted, the honest route is
  the shared hook engine reading a `<repo>/.agents/sandbox-policy.json` of
  **additional denies only**, enforced by the engine we control and structurally
  unable to loosen. Separate work item; speculative until asked for.
- `scripts/agent-policy.test.sh` (renamed from `antigravity-parity.test.sh`) now
  locks the convergence for both agents alongside the deny-list parity: the two
  modes must stay opposite, the merge must not mirror a directory, the overwrite
  must capture what it drops, and the warning must go quiet when nothing changed.
  Point 4 adds three more locks: a live preference survives an ordinary converge,
  a profile that lacks one is seeded `opus`/`medium`/`false`, and `--defaults`
  resets it and captures the replaced value.
