# ADR-0008 — Deletion is a human step: the shared hook engine has three tiers, and the ask tier is dialect-branched

- **Status:** Accepted (2026-08-25)
- **Date:** 2026-08-25
- **Relates to:** [ADR-0006](0006-antigravity-is-two-layer-like-claude.md) — this
  adopts the `force_ask` mechanism ADR-0006's Consequences deliberately deferred
  ("the hook can emit `force_ask` … wiring the mutating set through it is
  deliberately left as follow-up rather than half-built here"). Also
  [ADR-0007](0007-policy-templates-are-source-of-truth-for-every-agent.md): the
  policy half of this change reaches a profile on `up`, the hook ENGINE only on
  `build` + recreate.
- **Affects:** `sandbox_templates/claude/hooks/deny-destructive.sh` and its test
  suite, `sandbox_templates/antigravity/antigravity-settings.json` (comment
  only), `sandbox_templates/common/agent-notice.md`,
  `scripts/audit/probes/antigravity.py`. Landed as commit `e9deb82`
  (work/0004); the evidence is in
  [`docs/_archive/0004-deletion-is-a-human-step-plan.md`](../_archive/0004-deletion-is-a-human-step-plan.md).

## Context

The hook enforced "no bulk deletion" but not "deletion is a human step". Rule
`rm-recursive` blocked `git rm -r`; the agent then removed the same eight files
with eight plain `git rm <file>` calls, which nothing matched, and git pruned the
emptied directories itself. Nothing was concealed and the deletions were
pre-approved — the gap is one of rule shape, not conduct.

That generalises: **every bulk-shape block in this hook decomposes into per-item
calls**, and an agent under instruction to finish approved work will find the
decomposition without breaking the letter of any rule.

Before this work the engine had two tiers. WARN is invisible until someone greps
`/root/.cache/deny-destructive.log`; DENY is absolute, and the hook's own
`docs-install-cmd` comment records why a hard deny on ordinary verbs is wrong —
it "would fire on correct work and **train evasion**". The verbs in question
were not merely uncovered: `git checkout`, `git stash` and `git branch` sit on
**both** agents' static **allow** lists, so a rule for their destructive forms
narrows an existing grant.

## Decision

**1. The engine has THREE tiers — warn, ask, deny — not two.** `ask` is the
missing middle: the call does not proceed on the agent's authority, it proceeds
on the human's or not at all. Deny is reserved for the truly-never cases.

**2. The deletion class sits in the ask tier**, as six hook rules
(`deny-destructive.sh`, numbered in the file): **17 `git-rm`** (including
`git -C <dir> rm` and `git -c k=v rm`), **18 `git-discard`**
(`git checkout -- <path>` / `<ref> -- <path>` / `.` / `-f` / `--force`, and
`git restore <path>`; plain `git checkout <branch>`, `-b <branch>` and a
`--staged`-only `git restore` deliberately do NOT match), **19
`git-stash-drop`** (`drop`, `clear` only), **20 `git-branch-delete`** (`-d`,
`-D`, `--delete`), **21 `unlink`**, and **22 `rm-file`** — plain non-recursive
`rm`/`rm -f` outside the disposable-path carve-outs (`/tmp`, `/var/tmp`,
`/root/.cache`, `*.pyc`/`*.pyo`, and the path segments `.venv`, `node_modules`,
`__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `scratchpad`,
`build`, `dist`). Any non-carved target makes the whole call ask, and a target
the splitter cannot resolve (`rm $F`, `rm *.py`, argument-less `rm`) asks.
Recursive forms keep hitting the DENY rule `rm-recursive` first — the ask tier
never downgrades a block rule.

**3. The ask tier is dialect-branched, and the two branches are not the same
strength.** `emit_ask` emits `permissionDecision:"ask"` for claude and
`decision:"force_ask"` for antigravity. `agy` caches a plain `ask` approval as a
permanent **Always-Allow** grant, so `ask` there would mean "prompt once, then
delete freely forever". `force_ask` was read out of the shipped binary before
adoption — it is in `agy`'s own decision enum
(`allow|deny|ask|force_ask|deny_unless_prior_grant`) and its embedded docs say
*"Always prompt the user, ignoring cached permissions."* (work/0004 plan,
"Two dialects, two decision strings").

**4. Two measured facts make this a tightening rather than a weakening**, both
probed 2026-08-24 in a live profile container (Claude Code 2.1.241, scratch hook
loaded via `claude --settings`; work/0004 D1):

- Headless `claude -p` and Task **subagents** alike do **not** run an
  unresolvable `ask`. The call lands in the result JSON's
  `permission_denials[]` and the hook's reason string reaches the model as the
  tool result; the subagent neither auto-resolved nor escalated it. So with
  nobody at the prompt, `ask` is a **deny carrying the reason** — strictly
  stronger than these verbs' prior posture, which was *allow*.
- A hook `ask` **outranks a static `permissions.allow` entry** (probe D, against
  `git status`, which is on the allow list). This is what lets rules 18 and 19
  narrow `Bash(git checkout:*)` and `Bash(git stash:*)` **without editing either
  static list** — parity stays at 53/53 and no static entry moved.

**5. The static entries stay where they are, in both lists**, and the deny tier
gains their spelling-independent twins (`git-reset-hard`, `git-rebase`), so
`git -C <dir> reset --hard` no longer walks past a literal prefix. For `agy` the
static list is the tamper-resistant layer: a workspace `.agents/hooks.json` can
disable the hook by name (ADR-0006), and nothing in a workspace reaches
`settings.json`.

## Consequences

- **What an operator experiences:** interactively, a prompt on each deletion
  call, carrying the rule name and a reason that asks for the exact paths.
  Cleanups under the carve-out paths are silent. Headless or inside a subagent,
  the call is refused with that same reason, and the agent is expected to
  surface it rather than decompose around it — rule 17's reason says so in
  words.
- **`ask` presumes someone is present.** work/0013 §4 records this as a cost of
  any remote or @mention-driven agent: "the three-tier hook (warn/ask/deny)
  leans on `ask` re-prompting *someone who is present*. A remote caller changes
  who answers that prompt." Under a relay driver nobody is at the keyboard, and
  `agy`'s Always-Allow caching hazard rides along. Both tiers are to be
  re-examined before any remote driver is real.
- **The engine is baked into the image.** The tier-2 probe
  `engine_force_asks_deletion` reports FAIL on any profile still running a
  pre-0004 image until `scripts/profile.sh build` and a recreate. That is the
  correct signal, not a regression.
- The `agy`-side twin of probe D — that `force_ask` outranks a static
  `command(git checkout)` allow — is **`[unverified]`**: it needs an interactive
  `agy` session, which no automated probe drives. The plan carries it as a
  MUST-VERIFY, with the fallback of removing `command(git checkout)` and
  `command(git stash)` from both allow lists in one commit. Everything in the
  deletion set that is not on an allow list (`git rm`, `unlink`, plain `rm`,
  `git branch -d`) is unaffected either way.
- **The instruction layer does not bind subagents** — an orchestrator can
  override the notice at spawn time, which is what the origin episode did; the
  hook tier is what makes that not matter (probe C). The notice must also not
  call the ask tier a denial: `agent-notice.test.sh` requires a real deny entry
  behind every claimed denial.
- Rule `null-truncate` **stays WARN**. Its "promote to block after one clean
  week of warn-log review" comment is answered in the negative: 16 hits over ten
  weeks across three profiles, all false positives — mostly heredoc bodies
  matching a line-anchored regex.

## Alternatives considered

- **Deny the deletion verbs outright.** Rejected: it makes legitimately approved
  work impossible and invites the workaround-hunting the origin episode already
  demonstrated — the hook's own philosophy comment names trained evasion as the
  cost.
- **Static `ask` lists per agent instead of hook rules.** Rejected twice over.
  Under `agy`, `permissions.ask` **is** the Always-Allow-cached form that
  `force_ask` exists to bypass. Under claude, a static entry can only be a
  prefix (`Bash(git checkout:*)`), which cannot express the `checkout --` versus
  `checkout <branch>` distinction rule 18 requires — and probe D shows the hook
  `ask` already outranks the allow entry without one.
- **A plain `ask` on `agy` (one emit arm for both dialects).** Rejected: the
  first approval would become a permanent grant, so the tier would look
  installed and be one click from gone.

## Locked by

`bash sandbox_templates/claude/hooks/deny-destructive.test.sh` — **207/207**
(was 136/136). The load-bearing assertions:

- `agy_assert` has its own `ask` arm asserting the wire value **`force_ask`,
  never `ask`** — "git rm force_asks under agy  `<-- LOCK`", plus `rm-file`,
  `git-discard` (both forms), `git-stash-drop`, `git-branch-delete` and
  `unlink`. If this ever reads `ask`, the tier has silently become one-shot.
- The precision locks on rule 18: `git checkout <branch>` and
  `git checkout -b <branch>` do NOT ask; `git restore --staged` alone does NOT
  ask, while `--staged --worktree` does.
- `git rm -r` and `rm -rf` still **deny** — the ask tier never downgrades a
  block rule.
- The carve-out locks: one non-carved target in a mixed list asks; every rm
  segment of a compound command is inspected; a variable, quoted-variable or
  glob target asks; a path merely *containing* `build` is not carved out.
- Both `assert` and `agy_assert` gained a `default` arm in their
  `case "$want"` blocks. Before it, an unrecognised expectation — `want=ask` was
  exactly one — passed **vacuously**; proven by injecting two bogus expectations
  and watching the run report `136 passed, 2 failed`.
- The unknown-`--dialect=` locks: exit 2, **no** decision on stdout, a
  diagnostic on stderr — so a converged `hooks.json` naming a dialect the
  image's engine predates cannot leave the guardrail installed and inert.

Unchanged, and asserted so: `scripts/agent-policy.test.sh` 53/53 (no static list
was edited) and `scripts/agent-notice.test.sh` 13/13. `just test-offline` green;
`scripts/profile.sh <p> verify` green. Tier-2 adds `engine_force_asks_deletion`
in `scripts/audit/probes/antigravity.py`: a `git rm` envelope must come back
`force_ask` — not `ask`, and not `deny`.
