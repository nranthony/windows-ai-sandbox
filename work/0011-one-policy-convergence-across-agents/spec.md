# 0011 — One policy convergence across every code agent

**Status:** **Draft — direction chosen, awaiting go-ahead.** Raised 2026-08-23 by
owner after [0010](../0010-antigravity-permissions-and-hooks/spec.md) exposed the
inconsistency: `agy` policy now converges on every `up`, Claude Code's does not.
Pre-go-ahead corrections applied 2026-08-24 from an independent verification
audit (F4 overlap, F7 residual list, §2 discard capture, DoD 4/5/6, invariant 2);
0010 has since been built, brought up and verified live — the antigravity probe
runs its full in-container path OK on all three profiles, and the tier-2
`template_diff` DRIFT this spec predicts is now measured fact (see DoD 4).

**Shelf life:** delete or archive on merge.

**Security-sensitive.** Touches `scripts/profile.sh`, `scripts/init-profile-state.sh`,
`sandbox_templates/`, `justfile`, and both agents' policy files. Commits need a
`SECURITY IMPACT` line; `verify` (tier 1) green; `just test-offline` before done.

---

## 0. The problem, stated precisely

Editing a policy template today reaches a running profile by **three different
routes depending on which file you touched**, and one of them is a no-op:

| Edit | Reaches a profile via | Automatic on `up`? |
|---|---|---|
| `claude/claude-settings.json` | `reset-settings <p>` only | **no** — seeded create-only (`profile.sh:575`) |
| `claude/hooks/deny-destructive.sh` | `build` + recreate | no — it is baked into the image |
| `antigravity/*` | `up` / `recreate` / `rebuild` | yes (0010) |
| `skills/` | `up` / `recreate` / `rebuild` | yes (ADR-0005) |

So the 96-rule Claude deny list — the single most security-relevant file in the
repo — is the one thing that silently lags its template, and nothing reports it.
That is precisely the failure ADR-0005 was written about, never applied to the
file where it matters most.

Two more agents are coming (**opencode**, specified in
[0009](../0009-the-third-cli-runs-on-bun/spec.md); **codex** likely), so the fix
has to be a contract, not a third bespoke path.

---

## 1. What was measured (2026-08-23)

### F1 [V] — `up`, `recreate`, `rebuild` and `wipe` all already call `ensure_state`

The plumbing exists. The only reason Claude policy does not converge is the
`[[ ! -f ... ]]` guard at `profile.sh:575`. This is a small change, not a new
subsystem.

### F2 [V] — a repo-local Claude file can TIGHTEN but never LOOSEN

This corrects the premise in the request. From the Claude Code permissions
documentation:

> Rules are evaluated in order: deny, then ask, then allow. The first match in
> that order determines the outcome, and rule specificity doesn't change the
> order.

> The same holds across settings scopes: if user settings allow a permission and
> project settings deny it, the deny rule blocks it. **The reverse is also true:
> a user-level deny blocks a project-level allow**, because deny rules from any
> scope are evaluated before allow rules.

Precedence for *ordinary* keys is: managed → command line →
`.claude/settings.local.json` → `.claude/settings.json` → `~/.claude/settings.json`.
But `permissions` does not behave like an ordinary key: the lists are **unioned**
and evaluated deny-first across all scopes.

So "keep the local overrides in each repo be the files we modify if we would
like allow or deny on any specific rules" works in one direction only:

| In a repo's `.claude/settings.local.json` you can | |
|---|---|
| add a **deny** (tighten) | ✅ |
| add an **allow** for something not globally denied — a project's own build/test commands | ✅ |
| **re-allow something the sandbox globally denies** | ❌ **impossible** |

That is the right answer for a security sandbox and it should be stated in the
docs rather than discovered. Widening still goes through `with-egress.sh` and the
global template, which is [ADR-0003](../../docs/adr/0003-strict-egress-default.md)'s
position anyway.

One operational caveat: project-scope `allow` rules apply only after the folder
is **trusted**; `deny` and `ask` apply immediately.

### F3 [V] — `agy` has NO in-repo permission surface

Asked directly because the request assumed symmetry. It does not exist.

`agy`'s workspace customization root (`.agents/`, `.agent/`, `_agents/`,
`_agent/`) carries exactly five things, per its own embedded documentation:
**skills, rules, plugins, `mcp_config.json`, `hooks.json`**. There is no
permissions file among them.

The nearest thing is **project-scoped settings**, and they are not usable as a
per-repo override:

- The project proto does carry `permission_grants`, `file_access_policy`,
  `internet_policy`, `sandbox_mode`, `auto_execution_policy`,
  `artifact_review_mode`, `permission_preset`.
- Projects live host-side in `gemini-home/config/projects/<uuid>.json`, keyed by
  `folderUri` — **outside the repo**, so they are not a file a repo can carry.
- Two plausible on-disk shapes for grants were tried against a live `agy`; both
  produced `ApplyProjectPermissionGrants: no grants for project "CLI Project"`.
  The local project file is written by the app/server sync, and grants appear to
  be managed there rather than authored locally.

**The only in-repo lever `agy` has is `.agents/hooks.json` — which is the bypass
0010 blocks**, because it can disable the global guardrail by name. So the
mechanism that would serve as the override surface is the one that must stay
shut.

**Conclusion: the "per-repo override" pattern maps onto Claude Code and does not
map onto `agy` today.** Any plan claiming otherwise is claiming a file that does
not exist.

### F4 [V] — the ownership split is already clean

| | Template supplies | Agent writes back |
|---|---|---|
| Claude | `env`, `hooks`, `permissions`, `sandbox`, `_*comment` | `model`, `effortLevel`, `agentPushNotifEnabled` |
| `agy` | `permissions`, `toolPermission` | `colorScheme`, `model`, `enableTelemetry`, `trustedWorkspaces` |

**One overlap, and it matters: Claude writes into `permissions`.** An
in-session "Yes, and don't ask again" lands an `allow` rule in the sandbox's
most-owned key — F7 is the live proof, three sections down. The write-back
column above is what each agent writes *routinely*; `permissions` is written
*occasionally*, and the convergence design must capture that write before
overwriting (§2). For `agy` the split is clean.
Both templates are **strict JSON** with `_comment` keys — neither
uses `//` comments, so one merge implementation serves both. (The `//`-stripping
in `antigravity-parity.test.sh` is therefore dead code whose comment claims a
difference that does not exist; clean it up.)

### F5 [V] — opencode's model is a third semantics

From 0009: global config `~/.config/opencode/opencode.json`, in the
already-mounted profile `config/` dir, with `permission.{read,edit,bash,…}` and
**last-match-wins globs** — not deny-first. The contract must carry the
evaluation semantics per agent rather than assume Claude's.

0009's comparison table says `agy` has "none of ours" for permissions. That is
now wrong (0010 F8) and should be corrected when 0009 is unparked.

### F6 [V] — what an overwrite actually costs, measured

All three live profiles carry exactly three keys the template lacks:

| Key | fluidmomenta | nranthony | therapod |
|---|---|---|---|
| `model` | `claude-fable-5[1m]` | `opus[1m]` | `opus[1m]` |
| `effortLevel` | `high` | `high` | `medium` |
| `agentPushNotifEnabled` | `true` | `true` | `true` |

`env`, `hooks` and `sandbox` are byte-identical to the template on all three.
Settings backups add three more Claude Code has written there over time:
`theme`, `skipWorkflowUsageWarning`, `skipAutoPermissionPrompt`.

**The set is open-ended and grows with releases.** The repo's existing preserve
list — `USER_CUSTOMIZATION_KEYS = {"theme","model","effortLevel"}` at
`scripts/audit/probes/settings.py:30` — has already gone stale against it,
missing three of the six. That is the argument for declaring what the sandbox
**owns** rather than what to preserve, and for fixing that constant.

Scope check (Claude settings reference): `theme`, `model`, `effortLevel`,
`agentPushNotifEnabled` and `statusLine` are settable in **any** file, so they
can go per-repo. **`skipAutoPermissionPrompt` is user-or-managed only** — an
overwrite drops it with nowhere for the user to restore it, so the template must
own it or the one-time auto-mode notice returns forever.
**Decided (2026-08-24):** the Claude overwrite carries a **preserve list** of
four keys — `skipAutoPermissionPrompt`, `model`, `effortLevel`,
`agentPushNotifEnabled`.

The first is the mode rule (§2) applied literally: a key with nowhere else to
live is merged, not dropped. The other three are an **owner decision taken the
same day**, revising an earlier "exactly `skipAutoPermissionPrompt`" here. Their
scope permits a per-repo file, but the table above is the argument against
relying on that: all three live profiles had picked a model and an effort level,
and an overwrite makes every operator re-pick them after every `up` — friction
with no security value, since the sandbox has no opinion about any of the three.

Preserve has **two halves**, and the second is why the template changed too:

1. a **live** value survives convergence;
2. when the live file **lacks** the key, the **template default** seeds it.

Without (2), "preserve" on a fresh profile means "leave it unset" forever — and
after the pre-decision converge every profile was in exactly that state, its
keys already dropped. So `claude-settings.json` now carries `"model": "opus"`,
`"effortLevel": "medium"`, `"agentPushNotifEnabled": false` (owner-chosen;
`opus`, deliberately not a variant-suffixed id). They are **preserved, not
owned**: tier-1 `check_agent_policy_sync` compares the owned list only, so a
live value differing from these defaults is the design working rather than
drift, and tier-2's `template_diff` strips the preference keys from **both**
sides for the same reason.

The opt-out is `scripts/profile.sh <p> converge --defaults`, which overwrites
all four preserved keys with the template defaults instead of keeping the live
ones. It still writes the discard capture — under a `preference_resets` key
carrying the replaced value — because a reset the operator cannot undo is the
same silent loss the capture exists to prevent. `skipAutoPermissionPrompt` has
no template default, so `--defaults` leaves it alone rather than dropping it.

`skipWorkflowUsageWarning` is undocumented; scope unknown — it goes to the
discard file like any other unowned key.

### F7 [V] — a per-repo file cannot promote `ask` → `allow` either

`fluidmomenta`'s live `permissions` had drifted from the template: three rules
moved from `ask` to `allow` — `Bash(myclickup comment:*)`, `set-status`,
`update`. That is an in-session "always allow" landing in a **sandbox-owned**
key, and the owner confirms it was deliberate and wants it kept.

It cannot be kept in a repo-local file. Precedence is deny → ask → allow, first
match wins, across all scopes: *"a matching ask rule prompts even when a more
specific allow rule also matches the same call."* While the template lists these
under `ask`, no `.claude/settings.local.json` can promote them.

So keeping them means **editing the template**, which contradicts the
reads-allowed/writes-prompt design `docs/permissions-model.md` records. (The
sentence there quoting "13 reads … every write hits the prompt" is itself stale
twice over — the template's own `_myclickup_note` records the surface as 28
commands / 17 reads / 11 writes as of 0.6.0, and the operative control is the
`_ask_note` rule set, not the `defaultMode: auto` prompt. T00/T08 must correct
that paragraph too, not quote it.) Owner's call to overrule; scoped to exactly
those three, leaving the **eight** others — `create`/`claim`/`tag`/`untag`/
`depend`/`undepend`/`move`/`append-description` — prompting.

**Do not** instead drop them from `ask` so a per-repo allow can win: unlisted
commands fall to `defaultMode: auto`, where a classifier decides instead of the
human — weaker than today, before any repo file exists.

### F8 [V] — opencode's precedence runs the OPPOSITE way

From opencode's config docs, later sources override earlier:

```
1 remote → 2 global (~/.config/opencode/opencode.json) → 3 OPENCODE_CONFIG
→ 4 project (opencode.json in the repo) → 5 .opencode/ → 6 OPENCODE_CONFIG_CONTENT
→ 7 managed config files → 8 MDM (macOS only)
```

Claude gives a one-way ratchet (deny wins from any scope, repo can only tighten).
**opencode inverts it**: a repo-root `opencode.json` overrides the global config.
With last-match-wins globs and `allow` as opencode's default, a repo file can
re-allow what the sandbox denies — and the agent can write that file into its own
workspace. Same shape as the `agy` `.agents/hooks.json` bypass, except here it is
the documented, intended mechanism.

Therefore **seeding the deny posture into the global config puts it at level 2,
under anything a repo carries — that is not a boundary.** It belongs at level 7,
the managed config, which "overrides everything" and which "users cannot
override". Two open items, both for opencode's own Phase 0:

- the **Linux managed-config path is unstated** (docs give the macOS path only);
- **how a project file merges into the `permission` map** — whole-object replace
  or key-by-key — decides how much a repo can loosen. Unverified.

If the managed path is a system directory it is image-baked, which would not
converge on `up`. The fix is the trick `proxy/` already uses: bind-mount a
per-profile host directory onto it, giving both non-overridability and
convergence, substrate-neutral so it belongs in the base compose.

This **corrects 0009 D2**, which assumes the global config is the target.

Also: opencode does **not** write state back into `opencode.json` — TUI prefs
live in a separate `tui.json`. So there is nothing of the user's in the file we
write, and its mode is overwrite.

---

## 2. Direction

**Chosen: converge every agent's policy on every `up`/`recreate`. One function,
one descriptor table, one reset command — with the write mode chosen per agent
by one rule:**

> **Overwrite where the agent has somewhere else to put its preferences.
> Merge where it does not.**

| Agent | Mode | Why |
|---|---|---|
| Claude | **overwrite** + discard file + warning | per-repo files exist for nearly everything (F6) |
| `agy` | **merge** owned keys | no per-repo surface at all (F3), and `trustedWorkspaces` is functional state, not a preference |
| opencode | **overwrite** | never writes to the file; prefs are in `tui.json` (F8) |

### The overwrite must be loud, but not noisy

Owner's design, with the fatigue problem fixed. Three requirements:

1. **Warn only when the dropped set CHANGES.** Claude rewrites `model` and
   `effortLevel` every session, so an unconditional warning fires on every `up`
   forever and stops being read — going quiet in the reader's head exactly when
   a genuinely new key appears. Keep the last dropped set on disk and compare.
2. **Write the dropped keys to `claude-home/settings.discarded.json`, and name
   that path in the warning.** Not copy-paste from scrollback: recoverable,
   survives a lost terminal, and it means the data is on disk even on the silent
   runs. `claude-home/` is inside the container mount, so the file is
   agent-writable — treat it as recovery capture, not audit evidence; the
   authoritative drift signal is the tier-1 check (DoD 4), and tier-1 verify
   should learn the file is *expected* there (cf. the existing no-`*.bak*`
   assertion beside the seeded skills).
3. **The advice must be true per key.** `skipAutoPermissionPrompt` cannot go
   per-repo (F6) — resolved by the F6 decision: it rides the preserve list
   rather than the discard file. **Revised by the owner, 2026-08-24:** so do
   `model`, `effortLevel` and `agentPushNotifEnabled`, and the template gains
   defaults (`opus` / `medium` / `false`) so a profile that lacks the key gets
   seeded rather than left unset. Those four are therefore never in the discard
   file on an ordinary run — a preserved key is not a dropped key. The one time
   they do appear is under `converge --defaults`, the explicit opt-out, which
   overwrites them with the template defaults and records the replaced values
   under `preference_resets`.
4. **The capture must include owned-key content diffs.** Dropped *top-level*
   keys alone do NOT catch a change **inside** an owned key: an in-session
   `ask`→`allow` promotion lands in `permissions`, which the overwrite would
   revert with no record — the fluidmomenta promotion (F7) is exactly this, and
   silent reversion is the failure this item exists to prevent. So when an
   owned key's live content differs from the template, that diff is written to
   the discard file too and participates in the warn-on-change comparison.
5. **State the behavioural change.** Under overwrite, "Yes, and don't ask
   again" survives only until the next `up`/`converge` — captured, warned,
   reverted. Making a grant permanent means editing the template (as T00 does
   for the three myclickup writes). That is the intended posture; it goes in
   the docs (T08), not into someone's surprise.

With requirement 4 in place, this subsumes the "unexpected top-level key"
detector: a new key from a Claude release surfaces as a dropped key, and an
in-session `permissions` promotion surfaces as an owned-key diff, both on the
next `up`.

### Why overwrite won for Claude

An earlier draft of this spec argued for merge-owned-keys on the grounds that
resetting `model`/`effortLevel` every `up` would drive people away from running
`up`. Measured (F6), the cost is six preference keys, five of which can be set
per-repo, and the owner checks the model every session anyway — it is printed at
startup. The behavioural claim was a plausible story, not evidence, and it does
not survive contact with the actual delta.

Overwrite also buys something merge cannot: the live file **is** the template.
Merge only guarantees the owned keys, so a future Claude release putting
something security-relevant in a key we do not own would be silently preserved
rather than enforced. `permissions` gaining `additionalDirectories` and
`defaultMode` over time is that same shape of change.

`agy` still merges, and the asymmetry is principled rather than arbitrary: it has
nowhere else to put its preferences, and what it writes there is functional.

### Why the repo-local override story differs per agent, and that is acceptable

- **Claude**: `.claude/settings.local.json` in each repo, tighten-only (F2) —
  and it cannot promote `ask` to `allow` either (F7). Five of the six dropped
  preference keys can live there; `skipAutoPermissionPrompt` cannot (F6).
- **`agy`**: no in-repo surface exists (F3). Global policy only, for now.
- **opencode**: a repo-root `opencode.json` exists and **overrides** the global
  config (F8), so the deny posture cannot live in the global config at all.

Do not invent a cross-agent override file to paper over this. If per-repo
tightening for `agy` becomes a real need, the honest route is to teach the shared
hook engine to read a `<repo>/.agents/sandbox-policy.json` of **additional denies
only** — enforced by the engine we control, incapable of loosening. That is a
separate work item, and speculative until someone wants it.

### The single reset

One command, `just converge <profile>` — the verb this repo already uses
(`converge_skills`, `converge_antigravity`, ADR-0005). It runs exactly what `up`
runs, without touching containers: every agent's policy, the skills tree, and the
agent-notice sync.

Converging under a **running** agent is a lost-update race in both directions:
the session's in-memory settings can rewrite the file after the converge, and
the converge can clobber a grant the session just wrote. Every existing
`reset-*` branch ends with "restart claude/agy inside the container to pick up"
for exactly this reason (`profile.sh:1431/:1442/:1454`). `converge` keeps that
contract: when the profile's container is running it prints the same restart
instruction — and the §2 discard capture is what bounds the damage when the
instruction is ignored.

`reset-settings`, `reset-skills` and `reset-antigravity` are **deleted**, not
aliased. Per the repo's own standing rule against compatibility shims, and
because three near-identical commands with different semantics is the confusion
that produced this work item. Their disappearance is a documented breaking change
in the commit message.

---

## 3. The contract

Adding an agent becomes one descriptor plus a template, never a new code path.

| Field | Claude Code | Antigravity | opencode (0009) | codex |
|---|---|---|---|---|
| Template | `claude/claude-settings.json` | `antigravity/antigravity-settings.json` | `opencode/opencode.json` | tbd |
| Live path (in profile) | `claude-home/settings.json` | `gemini-home/antigravity-cli/settings.json` | **tbd — F8**: the managed-config path (per-profile bind mount), NOT the global `config/opencode/opencode.json` this row used to name | tbd |
| Sandbox-owned keys | `env`, `hooks`, `permissions`, `sandbox` | `permissions`, `toolPermission` | `permission`, `autoupdate` | tbd |
| Whole-file extras | — | `gemini-home/config/hooks.json` | — | tbd |
| Hook engine | `deny-destructive.sh` | same, `--dialect=antigravity` | none yet (0009 T-) | tbd |
| Eval semantics | deny-first, unioned across scopes | deny-first (measured, 0010) | **last-match-wins globs** | tbd |
| Per-repo override | `.claude/settings.local.json`, tighten-only | **none exists** | unknown — 0009 Phase 0 | tbd |

Invariants the descriptor must preserve, all of them already learned the hard way:

1. **Merge owned keys; never mirror a directory.** `gemini-home/config/` holds
   live `agy` state; a mirror deletes it (0010 F7).
2. **Never overwrite a file the agent writes to without first capturing what it
   wrote.** Both agents write runtime keys into their policy file, and Claude
   also occasionally writes into an owned key (`permissions` — F4/F7).
   Overwrite is permitted only behind the §2 discard-and-diff capture.
3. **Idempotent** — it runs on every `up`; a no-op change must not rewrite the file.
4. **Comment keys are `_`-prefixed and strict-JSON**, so the merge needs no JSONC parser.

---

## 4. Definition of done

1. `converge_agent_policy` in `profile.sh`, descriptor-driven, replacing the
   bespoke `converge_antigravity` body and the create-only Claude seed.
2. Claude policy converges on `up`/`recreate`/`rebuild`/`wipe` with a **four-key
   preserve list** — `skipAutoPermissionPrompt`, `model`, `effortLevel`,
   `agentPushNotifEnabled` (owner-decided 2026-08-24; see F6) — and all four
   demonstrably survive. The template carries defaults for the latter three
   (`opus` / `medium` / `false`), so a profile whose live file lacks a key is
   **seeded** rather than left unset. `converge --defaults` (and
   `just converge <p> --defaults`) is the opt-out: it overwrites all four with
   the template defaults and captures the replaced values to
   `settings.discarded.json` under `preference_resets`.
3. `just converge <profile>` added; the three `reset-*` commands removed, with
   the break called out in the commit and in **every** place that names them —
   the blast radius is larger than README/`profile-lifecycle`:
   `verify-sandbox.sh`'s remediation strings (:177/:190/:192/:251/:254 —
   printed *from inside containers*), the DEPLOYMENT paragraph in the shipped
   template's `_myclickup_note`, `init-profile-state.sh:82-83`'s create-only
   note, the `justfile` (:176-187), `profile.sh` header (:29-33) and help
   (:1607), `docs/extending-a-profile.md:103/:163`,
   `docs/sandbox-design-notes.md:30`, `docs/deny-destructive-hook-plan.md:29`,
   and ADR-0006:123.
4. Tier-1 verify asserts the LIVE Claude policy matches the template on the
   owned keys — the drift detector that does not exist today. The tier-2
   `template_diff` check needs its **constant** fixed, not its path: measured
   2026-08-24, `stage-audit-package.sh` stages the template on every `audit`
   (`profile.sh:1395`), all three profiles carry it md5-identical to the
   source, and an absent file reports UNKNOWN, never OK. The real defect is the
   stale `USER_CUSTOMIZATION_KEYS` (`settings.py:30`): the 2026-08-24 audit
   JSONs report DRIFT on all three profiles (`agentPushNotifEnabled`
   everywhere; plus `permissions` on fluidmomenta — F7 caught live). T02's
   constant fix clears it; the check then stands as-is.
5. `antigravity-parity.test.sh` becomes `agent-policy.test.sh` (T07 — renamed,
   per the plan; the rename touches the `justfile` eight-suite list and every
   `AGENTS.md` paragraph naming the file and its 28/28 count), covering the
   generalised converge for both agents, with the dead `//`-stripping removed.
   All suites green.
6. Docs: `permissions-model.md` gains the tighten-only rule and the per-agent
   override table (and the F7 correction to its stale "13 reads" paragraph);
   `ARCHITECTURE.md`, `AGENTS.md`, `README`, `profile-lifecycle.md` updated;
   ADR-0005 extended **by supersession** — a short ADR-0007 pointing back at
   it, per the append-only rule (plan T10, never "amend in place") — records
   that policy convergence now covers every agent.
7. 0009's comparison table cell corrected where it still says `agy` has "none
   of ours" (`0009/spec.md:136` — the 2026-08-23 correction block landed but
   left the cell). 0009's `plan.md` still targets the global-config path this
   spec's F8 rejects; the full fold is deferred to
   `docs/incoming/2026-08-24-work-item-audit-corrections.md` after this item
   merges.

**Out of scope:** the `agy` per-repo override (F3); `force_ask` (0010 follow-up);
opencode and codex wiring beyond leaving the descriptor slot ready.
