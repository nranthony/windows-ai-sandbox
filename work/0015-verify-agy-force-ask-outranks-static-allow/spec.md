# 0015 — Verify that `agy` `force_ask` outranks a static `command(git checkout)` allow

**Status:** Open — captured 2026-08-26. The single `[unverified]` in
[ADR-0008](../../docs/adr/0008-deletion-is-a-human-step.md) that is a
security question rather than a historical one. **The measurement is the
owner's** (it needs an interactive `agy` session, which no automated probe
drives); everything around it — what to run, what each outcome means, what to
do next, and what to write down — is here so the session is five minutes, not
an afternoon.

**Exit rule:** archive this folder to [`docs/_archive/`](../../docs/_archive/)
once ADR-0008 carries a dated resolution note (§5), whichever way the
measurement went.

---

## 1. The question

The shared hook engine (`sandbox_templates/claude/hooks/deny-destructive.sh`)
puts the deletion class — rules 17–22, including `git-discard` (rule 18:
`git checkout -- <path>`, `git checkout .`, `git restore <path>`) and
`git-stash-drop` (rule 19) — in the **ask** tier. Both agents also carry a
**static allow** for the harmless forms of the same commands:

| Agent | Static allow | Hook emits on the destructive form |
|---|---|---|
| claude | `Bash(git checkout:*)`, `Bash(git stash:*)` (`claude-settings.json:63-64`) | `permissionDecision:"ask"` |
| `agy`  | `command(git checkout)`, `command(git stash)` (`antigravity-settings.json:18-19`) | `decision:"force_ask"` |

For **claude** it is measured (work/0004, archived) that the hook's `ask`
**outranks** the static allow: `git checkout -- <path>` prompts even though
`git checkout:*` is allowed. That is what lets the deletion rules narrow an
allow without either static list being edited.

For **`agy`** the equivalent claim — that `force_ask` outranks
`command(git checkout)` — has **never been measured**. If it does not hold,
rules 18 and 19 are inert *for `agy` only*: the static allow wins silently and
`git checkout -- <path>` discards work with no prompt. Everything else in the
deletion set (`git rm`, `unlink`, plain `rm`, `git branch -d`) is on no allow
list and is unaffected either way.

Tier-2 already has a probe for the hook's *output* on this path
(`scripts/audit/probes/antigravity.py`, `engine_force_asks_deletion`) — it
proves the engine emits `force_ask`. It cannot prove `agy` *honours* it over
the allow, because that resolution happens inside `agy`.

## 2. The measurement (owner, interactive, ~5 min)

Any profile whose image carries the current hook engine (a pre-0004 image
reports `engine_force_asks_deletion` FAIL in tier 2 — rebuild first).

1. `scripts/profile.sh <profile> attach`, then inside the container, in a
   throwaway checkout (or `/workspace/<repo>` with a deliberately scratch
   file), create an uncommitted edit:
   ```
   cd /workspace/<repo> && echo probe >> PROBE.tmp && git add PROBE.tmp && echo more >> PROBE.tmp
   ```
2. Start `agy` interactively and ask it, in plain words, to run
   `git checkout -- PROBE.tmp` (the pathspec form — rule 18 does not fire on
   `git checkout <branch>`).
3. Observe **exactly one** of:
   - **A prompt appears** naming the `git-discard` rule text ("this discards
     uncommitted changes…"). → `force_ask` outranks the allow. **Holds.**
   - **The command runs with no prompt** and `PROBE.tmp` loses the second
     line. → the static allow won. **Does not hold.**
   - **The command is blocked outright** (not a prompt). → unexpected; the
     hook's fail-closed posture may have tripped — check the hook's stderr in
     the session and re-run before concluding anything.
4. Repeat once with `git stash drop` after a `git stash` (rule 19), for the
   second allow entry.
5. `rm PROBE.tmp; git reset -q PROBE.tmp` — leave the checkout as found.

Record the `agy` version (`agy --version`) with the result; a later `agy`
release can change the answer.

**Version now in the image, as of the 2026-08-26 `build --refresh-ai`:** `agy`
**1.1.21**, `claude` **2.1.246**. The refresh happened while this item was open
and moved the CLI the probe measures, so a result recorded against an earlier
`agy` would not answer for what the profiles now run. Nothing else about the
premise changed: rules 18/19 and both static allow entries are untouched.

## 3. If it HOLDS

Nothing changes in the trees. Write the resolution note (§5) and archive this
folder. Consider adding the measured behaviour to the ADR-0008 `agy` paragraph
in AGENTS.md as "measured, not assumed" so it matches the claude sentence.

## 4. If it DOES NOT hold — the fallback

The plan (archived, `docs/_archive/0004-deletion-is-a-human-step-plan.md`
§D1) names the fallback: remove the two allow entries from **both** lists in
**one** commit, so neither agent can run any `git checkout` / `git stash` form
unprompted.

1. Delete `"command(git checkout)"` and `"command(git stash)"` from
   `sandbox_templates/antigravity/antigravity-settings.json`, and
   `"Bash(git checkout:*)"` and `"Bash(git stash:*)"` from
   `sandbox_templates/claude/claude-settings.json`. Both, or
   `scripts/agent-policy.test.sh` fails — it diffs the two lists exactly, in
   both directions, with no exception list. That is the point: the two lists
   must not disagree about this.
2. `bash scripts/agent-policy.test.sh` (53/53) and
   `bash sandbox_templates/claude/hooks/deny-destructive.test.sh` (207/207 —
   the hook is untouched, this is a no-regression run).
3. Cost, stated so it is chosen and not discovered: plain `git checkout
   <branch>` and `git stash` (push) now **prompt** in both agents, every time.
   Under claude's `defaultMode: auto` an unlisted command goes to the
   classifier, so the prompt is not guaranteed either — if that matters, add
   both to the **ask** list instead of merely removing the allow, which makes
   the prompt a stated rule (the `_myclickup_note` in `claude-settings.json`
   explains why absence alone is not a rule).
4. Commit message states the security impact (a friction increase taken
   deliberately because `agy` does not honour `force_ask` over a static allow —
   with the `agy` version measured). Then `scripts/profile.sh <p> converge`
   per profile; no rebuild (policy converges, the engine is unchanged).

## 5. Write-back (either outcome)

ADR-0008 is Accepted and append-only: do **not** edit its Decision. Add a
dated header note, the same form ADR-0005 and ADR-0009 carry:

> **Note (YYYY-MM-DD):** the `agy` `[unverified]` below was measured in an
> interactive session (`agy` vX.Y.Z): `force_ask` DOES / DOES NOT outrank
> `command(git checkout)`. [If not: the fallback in the archived 0004 plan §D1
> was applied in commit `<sha>`.] See `docs/_archive/0015-…` for the probe.

Then archive this folder.

## 6. Non-goals

- Automating the probe. `agy`'s interactive permission resolution has no
  headless equivalent that reproduces it; a headless run would measure a
  different code path and report a false answer with confidence.
- Touching the hook engine. It is proven to emit `force_ask`; the question is
  entirely on `agy`'s side of the pipe.
