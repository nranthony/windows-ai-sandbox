# 0011 — One policy convergence across every code agent

**Status:** **Draft — direction chosen, awaiting go-ahead.** Raised 2026-08-23 by
owner after [0010](../0010-antigravity-permissions-and-hooks/spec.md) exposed the
inconsistency: `agy` policy now converges on every `up`, Claude Code's does not.

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

No overlap. Both templates are **strict JSON** with `_comment` keys — neither
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

---

## 2. Direction

**Chosen: converge every agent's policy on every `up`/`recreate`, by merging the
keys the sandbox owns and leaving every other key alone. One function, one
descriptor table, one reset command.**

### Why merge-owned-keys rather than whole-file overwrite

The request said overwriting Claude's settings is fine. It is *nearly* fine, and
the small difference is worth taking:

- Blind overwrite resets `model` and `effortLevel` on **every `up`**. That is a
  daily papercut whose predictable outcome is people avoiding `up` — which
  re-creates the drift this work exists to remove.
- The merge is not extra machinery. `converge_antigravity` already does exactly
  this and is already tested; generalising it is strictly less code than two
  mechanisms.
- Inverting the list is what makes it safe: the sandbox declares the keys it
  **owns**, and everything else is preserved by default. A new Claude runtime key
  survives automatically; a new sandbox-owned key must be added deliberately.

Everything security-relevant — `permissions`, `hooks`, `env`, `sandbox` — is
owned and therefore overwritten wholesale on every `up`, which is what was
actually asked for.

### Why the repo-local override story differs per agent, and that is acceptable

- **Claude**: `.claude/settings.local.json` in each repo, tighten-only (F2).
  Document the one-directional limit.
- **`agy`**: no in-repo surface exists (F3). Global policy only, for now.
- **opencode**: 0009 Phase 0 must answer whether one exists before it is wired.

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
| Live path (in profile) | `claude-home/settings.json` | `gemini-home/antigravity-cli/settings.json` | `config/opencode/opencode.json` | tbd |
| Sandbox-owned keys | `env`, `hooks`, `permissions`, `sandbox` | `permissions`, `toolPermission` | `permission`, `autoupdate` | tbd |
| Whole-file extras | — | `gemini-home/config/hooks.json` | — | tbd |
| Hook engine | `deny-destructive.sh` | same, `--dialect=antigravity` | none yet (0009 T-) | tbd |
| Eval semantics | deny-first, unioned across scopes | deny-first (measured, 0010) | **last-match-wins globs** | tbd |
| Per-repo override | `.claude/settings.local.json`, tighten-only | **none exists** | unknown — 0009 Phase 0 | tbd |

Invariants the descriptor must preserve, all of them already learned the hard way:

1. **Merge owned keys; never mirror a directory.** `gemini-home/config/` holds
   live `agy` state; a mirror deletes it (0010 F7).
2. **Never overwrite a file the agent writes to.** Both agents write runtime keys
   into their policy file.
3. **Idempotent** — it runs on every `up`; a no-op change must not rewrite the file.
4. **Comment keys are `_`-prefixed and strict-JSON**, so the merge needs no JSONC parser.

---

## 4. Definition of done

1. `converge_agent_policy` in `profile.sh`, descriptor-driven, replacing the
   bespoke `converge_antigravity` body and the create-only Claude seed.
2. Claude policy converges on `up`/`recreate`/`rebuild`/`wipe`; `model`,
   `effortLevel` and `agentPushNotifEnabled` demonstrably survive.
3. `just converge <profile>` added; the three `reset-*` commands removed, with
   the break called out in the commit and in `README`/`profile-lifecycle`.
4. Tier-1 verify asserts the LIVE Claude policy matches the template on the
   owned keys — the drift detector that does not exist today. The tier-2
   `settings.py` `template_diff` check reads
   `/workspace/temp_audit_package/config/claude-settings.json`, a path present in
   one profile, so for most profiles it silently does not run; fix or retire it.
5. `antigravity-parity.test.sh` extended to cover the generalised converge for
   both agents, and its dead `//`-stripping removed. All suites green.
6. Docs: `permissions-model.md` gains the tighten-only rule and the per-agent
   override table; `ARCHITECTURE.md`, `AGENTS.md`, `README`,
   `profile-lifecycle.md` updated; ADR-0005 amended or a new ADR records that
   policy convergence now covers every agent.
7. 0009's comparison table corrected where it says `agy` has no permissions.

**Out of scope:** the `agy` per-repo override (F3); `force_ask` (0010 follow-up);
opencode and codex wiring beyond leaving the descriptor slot ready.
