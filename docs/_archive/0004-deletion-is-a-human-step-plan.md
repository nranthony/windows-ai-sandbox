# Deletion is a human step — the hook grows a third tier

**Status:** Rewritten and implemented 2026-08-24 on `feat/0010-antigravity-guardrails`.
Raised 2026-08-12 from an in-container episode; parked until the two-dialect
engine (work/0010, ADR-0006) and policy convergence (work/0011, ADR-0007) landed,
because both changed the answer.

**Exit rule:** delete this folder, or move to [`docs/_archive/`](../../docs/_archive/),
when the work merges.

**Security-sensitive.** Touches `sandbox_templates/claude/hooks/deny-destructive.sh`
(now shared by TWO agents), `sandbox_templates/antigravity/antigravity-settings.json`
and `sandbox_templates/common/agent-notice.md`. Green-before-merge gate:

| Suite | Before | After |
|---|---|---|
| `sandbox_templates/claude/hooks/deny-destructive.test.sh` | 136/136 | 207/207 |
| `scripts/agent-policy.test.sh` | 53/53 | 53/53 |
| `scripts/agent-notice.test.sh` | 13/13 | 13/13 |
| `just test-offline` (nine checks) | green | green |
| `scripts/profile.sh <p> verify` | green | green |

Plus a `SECURITY IMPACT` line in the commit, per AGENTS.md.

---

## Origin — what actually happened

Reported by a Fable 5 session working inside a profile. Nothing was covertly
bypassed; the sequence was:

1. A Stage A subagent tried `git rm -r` on two skill directories.
2. The hook blocked it. Rule `rm-recursive` matches a short-flag cluster
   containing `r` after any `rm` token — `git rm -r` trips it, and the rule's
   own header comment already records this as a *deliberate* false positive.
3. The agent then removed the eight files individually with plain
   `git rm <file>`, which nothing blocked, and git pruned the emptied parent
   directories on its own.
4. It reported the deviation rather than concealing it, and the deletions were
   pre-approved — named explicitly in the plan and in the handoff decision.

The authorization chain held. What the episode exposes is a **shape gap**: the
hook enforced "no bulk deletion" but not "deletion is a human step." Anything
deletable in bulk is deletable as N single-target calls, and an agent under
instruction to complete approved work will find that decomposition without ever
violating the letter of the rule.

That generalizes past deletion. **Every bulk-shape block in this hook is
decomposable into per-item calls** — the same reasoning applies to `find -exec`
(rule `find-exec`), and would apply to any future "wide blast radius" rule.
Deciding this one decides the class.

(The incident repo is not this one. An earlier draft cited an empty
`git log --diff-filter=D` over `*skills*` here as evidence; that is no longer
empty — two vendor-script retirements match it — and the line is dropped. The
conclusion is unaffected: only the hook and the notice block live here.)

## What the hook covered before this work

Read before designing: several of the "gaps" proposed in the source thread were
already handled, and mis-scoping the change is how a rule ships inverted. Rules
are named, not numbered by line — every line number in the first draft of this
plan had moved twice by the time anyone read it.

| Verb | Status before |
|---|---|
| `rm -rf` and every flag spelling | **blocked** — `rm-recursive`, spelling-independent |
| `git rm -r` | **blocked** — `rm-recursive`, deliberate false positive |
| `git clean` | **blocked** — `git-clean` |
| `truncate` | **blocked** — `truncate` |
| `shred`, `dd of=`, `mkfs` | **blocked** — `shred`, `dd-write`, `mkfs` |
| `git reset --hard`, `git rebase` | **denied** in BOTH static lists — but by *literal prefix*, so `git -C <dir> reset --hard` walks past both (the exact bypass class `rm-recursive` was written to close) |
| `: > file` / bare `> file` clobber | **WARN only** — `null-truncate`; its own comment says "promote to block after one clean week of warn-log review" |
| clobber into `/workspace` | **WARN only** — `workspace-overwrite` |

Genuinely uncovered, and the subject of this work:

- bare `git rm <file>` — the exact route taken
- `git checkout -- <path>` / `git restore <path>` — discarding uncommitted work
  is destruction with no undo, and reads as an ordinary navigation verb
- `git stash drop` / `git stash clear`
- `git branch -D`
- `unlink <file>`
- plain non-recursive `rm <file>` / `rm -f <file>`

Not "uncovered" in the sense the first draft implied: `git checkout`, `git stash`
and `git branch` sit on BOTH agents' **allow** lists. Adding rules for their
destructive forms is **narrowing an existing grant**, not filling a hole — which
is why D1's precedence question below (does a hook `ask` outrank a static
`allow`?) was load-bearing and had to be measured before anything shipped.

Out of scope, recorded in Future scope: `cp /dev/null file`, `mv` over an
existing path, and Write/Edit wholesale rewrites (D5).

## The design: a third tier, `ask`, dialect-branched

`ask` is the missing middle between WARN (invisible until someone greps the log)
and DENY (absolute). A hard deny on the deletion verbs makes legitimately
approved work impossible and invites exactly the workaround-hunting the episode
showed; the hook's own philosophy comment (in the `docs-install-cmd` arm) says
blocking legitimate work "would fire on correct work and **train evasion**."

It is the first weakening-*shaped* change to a fail-safe file, so its rationale
is on the record either way. In fact it is not a weakening at all: every verb
that gains an `ask` was previously **allowed**, several of them explicitly on an
allow list. Nothing that was denied became askable.

### Two dialects, two decision strings

The engine is ONE rule table with two dialects (ADR-0006). `emit_ask` must
branch, and the two branches are NOT the same strength:

| Dialect | Emitted | Why not the other one |
|---|---|---|
| claude | `permissionDecision:"ask"` | Claude's ask re-prompts every time |
| antigravity | `decision:"force_ask"` | a plain `ask` approval is cached by `agy` as a permanent **Always-Allow** grant — first approval unlocks deletion forever |

`force_ask` was verified in the shipped binary before adoption, not assumed:

```
$ docker exec ai-sandbox-<p> strings -n 6 /usr/local/bin/agy | grep force_ask
        *   `"force_ask"`: Always prompt the user, ignoring cached permissions.
TYPE_FORCE_ASK_HOOK
json:"decision" jsonschema:"required,enum=allow,enum=deny,enum=ask,enum=force_ask,enum=deny_unless_prior_grant" …
```

This is 0010's deliberately-deferred D3 (ADR-0006 Consequences: "the hook can
emit `force_ask` … wiring the mutating set through it is deliberately left as
follow-up rather than half-built"). **This item adopts the mechanism** for the
deletion set. It does not wire the eight `myclickup` writes through it — see
Future scope.

## Decisions

### D1 — `ask`, and it is not weaker headless. MEASURED, not assumed.

The first draft called this blocking: *"what does `ask` do when there is no human
at the prompt? If it silently resolves to allow in any of those, the whole
approach is dead."* It was measured on 2026-08-24 inside a live profile
container (`ai-sandbox-nranthony`, Claude Code 2.1.241), with a scratch hook
returning `ask` for one marked command, loaded via `claude --settings` so no
profile state was touched.

| Probe | Setup | Result |
|---|---|---|
| A | `claude -p`, top level, hook returns `ask` for `echo probe-ask-marker-A` | **Command did NOT run.** Recorded in the result JSON's `permission_denials[]`; the hook's reason string was handed to the model verbatim as the tool result. |
| C | `claude -p`, hook `ask`, command issued from a **Task subagent** — the exact episode shape | **Command did NOT run.** Subagent received `<error>probe: this command needs human confirmation</error>`, reported it, and declined to retry. It did NOT escalate to the top level and was NOT auto-resolved. |
| D | `claude -p`, hook `ask` for **`git status`**, which IS on `permissions.allow` | **Command did NOT run.** A hook `ask` **outranks a static `allow`.** |
| B | `--permission-mode bypassPermissions` | Structurally **unavailable** in this sandbox: *"--dangerously-skip-permissions cannot be used with root/sudo privileges for security reasons."* The container runs as root by design, so the one mode that could weaken this is unreachable here. |

So: **headless, an unresolvable `ask` is a deny that carries a reason.** That is
strictly stronger than today's posture on these verbs (which was *allow*), and
interactively it is a prompt — the intended behaviour. Probe D is the one that
made the git rules possible at all; without it, `git checkout --`/`git stash`
rules would have been inert against those allow-list entries.

Documentation check (independent, same day): the Claude Code docs do **not**
state what an unresolvable `ask` does in `-p` mode. They do state that
`PreToolUse` hooks "fire before any permission-mode check, in every permission
mode", that a hook `deny` blocks even under `bypassPermissions`, that `dontAsk`
mode auto-denies anything that would otherwise prompt, and that a fourth value
`"defer"` exists for `-p` runs driven by an Agent SDK wrapper. None of that
answers the question; the measurement above does, and it agrees with the
`dontAsk` direction. **Re-measure if Claude Code's permission model changes** —
probes A/C/D are cheap and reproducible from this table.

For `agy` the same question splits in two. That an unresolvable `force_ask` is
not an allow follows from ADR-0006's measured fail-closed posture. That
`force_ask` outranks a static `allow` entry (`command(git checkout)`) is the
`agy`-side twin of probe D and is **NOT yet measured** — it needs an interactive
`agy` session, which no automated probe can drive.

> **MUST-VERIFY (agy):** in an interactive `agy` session inside a profile, run
> `git checkout -- <path>` and confirm a prompt appears rather than the static
> `command(git checkout)` allow winning silently. If the static allow wins, the
> `git-discard` and `git-stash-drop` rules are inert **for `agy` only** (they are
> proven live for claude), and the fallback is to remove `command(git checkout)`
> and `command(git stash)` from both allow lists — a friction increase that must
> be taken deliberately, in both files, in one commit.
>
> Everything in the deletion set that is NOT on an allow list (`git rm`,
> `unlink`, plain `rm`, `git branch -d`) is unaffected by this question in either
> agent.

### D2 — verb tiers

**Ask tier** (new hook rules), for both dialects:

| Rule | Matches | Deliberately does NOT match |
|---|---|---|
| `git-rm` | `git rm`, incl. `git -C <dir> rm`, `git -c k=v rm` | `git commit -m "remove rm"` (the global-option prefix is enumerated, so a subcommand that is not `rm` cannot reach the rule) |
| `git-discard` | `git checkout -- <path>`, `git checkout <ref> -- <path>`, `git checkout .`, `git checkout -f`, `git restore <path>` | **`git checkout <branch>` / `git checkout -b <branch>` — navigation must not trip it**, and `git restore --staged <path>` (unstages only; it does not touch the worktree) |
| `git-stash-drop` | `git stash drop`, `git stash clear` | `git stash`, `git stash push/list/show/apply/pop` |
| `git-branch-delete` | `git branch -d`, `-D`, `--delete` | `git branch`, `-a`, `-v`, `--list`, `--sort=-committerdate` |
| `unlink` | `unlink <file>` | — |
| `rm-file` | plain non-recursive `rm` / `rm -f` outside the carve-outs (D4) | anything under the carve-out paths |

`git-branch-delete` is deliberately **broader** than the `-D` this item was
scoped to. The Bash arm lowercases the command line before matching (paths are
case-sensitive on Linux, so a casing mismatch could not reach a protected path)
— which makes `-D` and `-d` indistinguishable in `$norm`. Rather than add a
case-sensitive matcher for one flag, both spellings ask: `-d` is a deletion too,
and asking about it is a tightening, not a hole.

**Deny tier** (new hook rules): `git-reset-hard` and `git-rebase`,
spelling-independent, so `git -C <dir> reset --hard` and
`git --git-dir=… rebase` no longer walk past the literal-prefix static entries.
This is the same defect `rm-recursive` was created to fix, applied to the two
verbs that still had it.

**The static entries stay exactly where they are, in BOTH lists.** They are not
moved into the hook. For `agy` the static list is the tamper-resistant layer —
a workspace `.agents/hooks.json` can disable the hook by name (measured, 0010
Phase 0) and nothing in a workspace can reach `settings.json`. The hook rules
are the spelling-independent twins of those entries, not replacements.

**No static-list edits are needed by this work**, and that is a decision rather
than an omission:

- The ask tier cannot live in `agy`'s static list at all — `permissions.ask`
  there is the Always-Allow-cached form, which is precisely what `force_ask`
  exists to bypass.
- It does not need to live in Claude's `permissions.ask` either: probe D shows
  a hook `ask` already outranks `allow`, and a static entry would have to be
  a prefix (`Bash(git rm:*)`), which cannot express the `checkout --` vs
  `checkout <branch>` distinction D2 requires.
- So `scripts/agent-policy.test.sh` stays at 53/53 and parity is untouched. Any
  future static `ask` addition still lands in **both** files in one commit or
  parity goes red.

### D3 — rule `null-truncate` stays WARN. The review finally happened.

Its comment has said "promote to block after one clean week of warn-log review"
since 2026-05. The review ran 2026-08-24 against
`/root/.cache/deny-destructive.log` in all three live profiles:

| Profile | Window | `null-truncate` | `workspace-overwrite` |
|---|---|---|---|
| therapod | 2026-06-10 → 2026-08-22 | 7 | 3 |
| nranthony | 2026-08-04 → 2026-08-18 | 6 | 11 |
| fluidmomenta | 2026-07-20 → 2026-08-22 | 3 | 10 |

**16 hits over ten weeks, and every single one is a false positive.** They fall
into three shapes, none of them a destructive clobber:

1. Heredoc file authoring — `cat > docs/runbooks/x.md <<'EOF'`,
   `cat > .claude/skills/verify-deploy/SKILL.md <<'EOF'`.
2. Heredoc **appends** — `cat >> tests/test_silver_hrv.py << 'EOF'`. An append
   is not a clobber at all.
3. Heredoc *stdin* scripts — `python3 - <<'PY'`. No file is written.

And the mechanism is worse than "high variance". Reproduced on the host:

```
$ printf '…{"command":"cat > /workspace/x/doc.md <<EOF\n# Title\n\n> a blockquote\n\nEOF"}}' | sh deny-destructive.sh
# logs: null-truncate
$ # same command, body without a leading-'>' line
# logs: nothing
```

The `^` in the rule's ERE anchors at **every line of a multi-line command**, so
a markdown blockquote or a `>>>` doctest **inside a heredoc body** matches the
rule. Most of the 16 are the rule firing on document *content*, not on a shell
redirect.

**Decision: keep WARN, and the comment's promotion instruction is now answered
in the negative.** Promoting it would block ordinary file authoring at a 16/16
false-positive rate — the textbook way to train evasion. The comment is rewritten
to record the evidence so nobody re-opens it from first principles.

The line-anchoring defect is real but is **not** a security issue (a warn rule
that over-fires costs log noise), and narrowing a rule is a weakening-shaped
change that deserves its own commit and its own evidence. Future scope.

`workspace-overwrite` (24 hits) was not part of D3 and is unchanged.

### D4 — plain `rm <file>` asks, with path carve-outs

This is the highest-friction item on the list: build scratch, temp files and
`.pyc` cleanup all hit it, and a prompt on every temp-file cleanup trains exactly
the evasion the hook's own philosophy warns about. So `rm-file` asks **only when
a target is outside the carve-outs**.

A target is carved out (silent pass) when it is:

| Carve-out | Justification from this repo's own model |
|---|---|
| `/tmp/**`, `/var/tmp/**` | `noexec` tmpfs, wiped on recreate — AGENTS.md's state table calls it disposable, and the notice tells agents not to put anything durable there |
| `/root/.cache/**` | same table: caches are "disposable by design" |
| any path segment `.venv`, `node_modules`, `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `scratchpad` | rebuildable from a manifest or a cache; `scratchpad` is the agent harness's own temp dir |
| any `*.pyc` / `*.pyo` | build artifact |
| a path segment `build` or `dist` | build output |

Two properties of the implementation are load-bearing and both are locked by
tests:

- **ANY non-carved target makes the whole call ask.** `rm -f /tmp/x /workspace/a.py`
  asks. A carve-out is a hole if one carved target can launder a list.
- **A target the parser cannot resolve asks.** `rm $F`, `rm "$file"`, `rm` with
  no arguments, and a target arriving through `xargs` all ask rather than pass.
  Globbing is disabled (`set -f`) while the targets are split, so `rm *.py` is
  inspected as the literal token `*.py` and asks.

### D5 — Write/Edit destructive rewrite: **NO**

Hooking it is possible (the Edit/Write arm exists) but distinguishing "rewrote
the file" from "emptied the file" needs a payload heuristic over ordinary
editing traffic, and a false positive there blocks the agent's primary job. The
Edit/Write arm's existing rules all key on a *named file* or a *specific
dangerous value*; a size-delta heuristic keys on nothing stable. Not built, and
not left as a TODO — recorded here as declined with the reason.

### D6 — macolima: out of scope, and the port is now doubled

The sibling repo carries the `agy` port as of commit `1b8158f` (pending Mac
verification), so porting this means porting **two** layers there, not one. The
protected paths differ (`/home/agent/…` vs `/root/…`) and macolima has a kernel
write-protect this sandbox cannot have (the agent here IS root). Golden rule 3:
cross-check, never blind-copy. Separate item, after the Mac verification clears.

## Projected future — the third dialect is already scheduled

work/0009 adds **opencode** to this engine. That changes what "unknown dialect"
must mean, and the change is made *now*, with the ask tier, because this is the
commit that adds a decision string:

- The dialect parser used to coerce anything it did not recognise to `claude`.
  Under that behaviour a converged `hooks.json` saying `--dialect=opencode`
  against an image whose engine predates opencode would emit **claude-shaped
  output to opencode** — which opencode would not understand, so the guardrail
  would be installed and inert, silently. That is the exact failure shape
  ADR-0006 already recorded for `agy` ("`agy` treats a missing hook command as
  nothing to run and carries on unguarded, so this fails silently"), and the
  ordering that produces it (`converge` before `build`) is an ordinary mistake.
- **An unknown dialect now fails loudly**: a diagnostic on stderr and exit 2, no
  stdout. Exit 2 is the code Claude Code treats as "block and show the reason",
  and `agy` blocks on any non-zero exit — so the one behaviour that is wrong in
  every harness (guessing an output shape) is the one behaviour it will not do.
  This does **not** weaken claude's documented fail-OPEN posture: fail-open is
  about *runtime* breakage (bad envelopes, a jq error), which is unchanged. A
  wrong `--dialect=` is a deployment error in a sandbox-owned file the agent
  cannot write, and a deployment error should be visible on the first tool call.
- Adding opencode is therefore: one arm in `emit_pass`, one in `emit_block`, one
  in `emit_ask`, one input adapter, one posture note — and the suite's
  unknown-dialect assertions tell you if you missed one.

The suite's helpers were also given the missing `default` arm in their
`case "$want"` blocks (see Implementation, step 1). Before this work an
assertion with an unrecognised expectation — `want=ask`, which is exactly what
the first new rule needed — passed **vacuously**. A third dialect will bring a
fourth decision string; the arm is what stops that from silently un-testing the
suite.

## Future scope — named, with reasons, not built here

1. **The eight `myclickup` writes through `force_ask`.** They sit in both static
   `ask` lists, and under `agy` that means Always-Allow-cached: one approval
   makes `myclickup create` permanent for the profile. Now that the engine can
   emit `force_ask`, re-asserting that set in the hook is the natural follow-up
   and is what ADR-0006's consequence bullet was pointing at. Not done here
   because this item's evidence is about deletion, and the `myclickup` set needs
   its own decision about which writes deserve a per-call prompt.
2. **`null-truncate` line anchoring.** Restrict the match to the command's first
   line, or strip heredoc bodies before matching. Needs its own evidence run
   because it narrows a rule.
3. **`cp /dev/null file` and `mv` over an existing path.** Both are destructive
   shapes the ask tier could now carry. `mv` in particular needs a
   does-the-target-exist heuristic that the hook cannot evaluate from the
   envelope alone.
4. **macolima port** (D6), after the Mac verification of `1b8158f`.
5. **The instruction layer does not bind subagents.** The notice reaches the
   agent's standing instructions, but an orchestrator can override it at spawn
   time — which is what happened in the origin episode, where the orchestrator
   explicitly instructed the subagent to use `git rm` on the strength of the
   human's approval. That is a prompt-architecture problem, not a hook problem,
   and the hook tier is what makes it not matter: probe C shows the subagent's
   call is intercepted regardless of what its prompt says.

## Implementation

Landed in this order, each step green before the next:

1. **Test helpers first, and prove the arm bites.** `assert` and `agy_assert`
   both learned a third expectation (`ask`) *and* gained the `default` arm their
   `case "$want"` blocks never had. Verified by deliberately running an
   assertion with a bogus expectation and watching it FAIL rather than pass
   silently, before a single new rule existed. Suite green at 136/136 at the end
   of this step.
2. **`emit_ask()`** beside `emit_block`/`emit_pass`, dialect-branched, unknown
   dialect fatal (above). Keeps the `deny-destructive: <rule>: <msg>` reason
   prefix so log greps and the audit probe keep working.
3. **The deny-tier additions** (`git-reset-hard`, `git-rebase`), placed with the
   other block rules, before the ask tier — first hit wins, and a deny must win.
4. **The ask-tier rules** in D2/D4 order, each with positive and negative locks
   in both dialects; the `agy` side asserts `force_ask`, never `ask`.
5. **`null-truncate`'s comment** rewritten with D3's evidence.
6. **`antigravity-settings.json`'s `_comment_ask_cache`** made true — it claimed
   "the hook re-asserts this set as `force_ask`" when the hook contained no
   `force_ask` at all. It now says what is true: the engine emits `force_ask`
   for the deletion set, and the eight `myclickup` writes in `ask` are still
   cache-backed (Future scope 1).
7. **`sandbox_templates/common/agent-notice.md`** — the instruction half.
8. **Tier-2 probe**: `scripts/audit/probes/antigravity.py` gained one behaviour
   assertion, `engine_force_asks_deletion` — a `git rm` envelope must come back
   `force_ask`, not `ask` (one-shot) and not `deny` (this tier exists to keep
   approved deletions possible). **The engine is baked into the image**, so this
   reports FAIL on any profile still running a pre-0004 image until
   `scripts/profile.sh build`. That is the correct signal, not a regression.
9. **Docs**: `AGENTS.md` suite counts, `docs/permissions-model.md`,
   `docs/deny-destructive-hook-plan.md` (output contract + ruleset table +
   the warn-review section, which D3 discharges).

### The notice wording, and why it is worded that way

`scripts/agent-notice.test.sh` locks three rules the wording has to respect: no
repo-relative path, no host-side mechanism, and **every claimed denial must have
a real deny entry behind it**. An `ask` is not a deny, so the notice must not
say "denied" or "blocked" about the deletion set — a notice that over-claims a
denial is the dangerous direction, because the agent reads it, does not attempt
the thing, and the claim is never tested. The landed wording puts deletion in
its own bullet outside the "these fail" section, and says what actually happens:
the call is intercepted and needs the human's confirmation, so propose the exact
paths and wait.

## Verification record (2026-08-24)

- `deny-destructive.test.sh` **207/207** (was 136/136). The default-arm change
  was proven before any rule landed: with two deliberately-bogus expectations
  injected, the run reported `136 passed, 2 failed` and named both —
  *"unknown expectation 'notADecision' — assertion would have passed vacuously"*.
- `agent-policy.test.sh` 53/53, `agent-notice.test.sh` 13/13 — both unchanged,
  as intended: no static list was edited.
- `just test-offline` green, exit 0, all nine checks plus `check-upstreams`.
- `scripts/profile.sh nranthony verify`: 52 passed, 0 failed, 1 pre-existing
  warning (project `no-build=false` opt-outs, ADR-0004).
- **Live proof**, inside `ai-sandbox-nranthony` with the container's own `sh`
  and `jq`, driving the engine with synthetic envelopes: `git rm src/a.py`
  returned `permissionDecision:"ask"` under the claude dialect and
  `decision:"force_ask"` under antigravity, with an identical reason string;
  `rm /workspace/p/main.py` asked; `rm /tmp/scratch.txt` and
  `git checkout main` returned `{}`; `git -C /workspace/p reset --hard` denied;
  `--dialect=opencode` printed the diagnostic on stderr and exited 2 with empty
  stdout.
- **Observed, unrelated, not fixed here:** tier-1 verify reports policy DRIFT on
  `nranthony` for both agents. The drifting keys are the `myclickup` `allow`/`ask`
  entries from work/0011's 2026-08-24 promotion, which has not been converged
  into the live profiles yet. That is ADR-0007's detector working, and it is
  cleared by a `converge` (or the next `up`), not by anything in this item.

## Non-goals

- Re-litigating the episode. The chain was intact, the deviation was reported,
  and the deletions were approved. This is a rule-shape gap, not a conduct issue.
- Any change to the semantics of the pre-existing block rules.
- Anything about the Bash allow-list's *membership*. `git rm` is not on it; that
  is not what made this reachable. (The hook now narrows three entries that ARE
  on it — see D1 probe D — without editing either list.)
