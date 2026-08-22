# 0010 — Plan: Antigravity Tool Permissions and Pre-Tool Execution Hooks

Ordered steps. Read [`spec.md`](spec.md) first — findings are marked **[V]** verified against
the shipped `agy` binary or **[?]** open, and the open ones (F5, F6) **gate Phase 1**.

**Phase 0 is not a formality.** The first draft of this plan carried Phase 0 while the spec
already asserted its conclusions as findings. Two of those conclusions are load-bearing and
still unproven; if F5 comes back the wrong way, the hook-only design does not hold and Phase 1
is wasted work. Answer the questions, write the answers back into `spec.md`, then proceed.

---

## Phase 0 — Measure the contract

### T01 — Confirm the `PreToolUse` contract end to end

Working profile, real `agy`. Record every answer in `spec.md` and flip the marker to **[V]**.

1. **Registration.** Does `~/.gemini/config/hooks.json` load? The binary logs
   `loaded %d named hooks from %d hooks.json file(s)` and
   `No hooks.json found at %s` — use them as ground truth rather than inferring from
   behaviour. Confirm the count reflects the seeded file.
2. **Dispatch coverage.** With `"matcher": "*"` and a handler that logs and allows, exercise
   `run_command`, `write_to_file`, `replace_file_content`, `view_file`, `grep_search`. Record
   the exact `toolCall.name` strings observed — these become the engine's dispatch table and
   the D8 detector's assertion list.
3. **Payload shape.** Confirm `toolCall.args` key names per tool (`CommandLine`, `TargetFile`,
   `AbsolutePath`, `SearchPath`) and that the common fields (`conversationId`, `stepIdx`,
   `workspacePaths`) arrive as documented.
4. **Decisions.** Confirm `deny` halts dispatch and surfaces `reason` in the conversation.
   Confirm `ask` vs `force_ask` against the Always-Allow cache: approve once with "Always
   Allow", then re-run — `ask` should not re-prompt, `force_ask` should. This is the evidence
   for D3.

### T02 — Answer F6: what happens when the hook is broken

The failure posture (D5) cannot be designed until these are known. Four handlers, four runs:

| Handler behaviour | Question |
|---|---|
| `sleep 60` with `"timeout": 2` | Does a timeout allow, deny, or prompt? |
| `exit 1` with no stdout | Does a non-zero exit allow, deny, or prompt? |
| prints `not json` | Does unparseable stdout allow, deny, or prompt? |
| prints `{}` | Is a missing `decision` key allow, deny, or prompt? |

Then: run each of the four **under `--dangerously-skip-permissions`** and record whether the
handler executes at all.

**Outcome shapes the engine.** If agy allows on any of these, the agy adapter cannot fail
closed by dying — it must trap its own errors and print an explicit `deny`, and the timeout
value becomes a security parameter rather than a comfort setting.

### T03 — Answer F5: can a workspace file disable the guardrail

With a global `sandbox-guardrails` hook seeded and denying a known command:

1. Write `/workspace/<repo>/.agents/hooks.json` containing
   `{"sandbox-guardrails": {"enabled": false}}`. Re-run the denied command. Blocked or not?
2. Repeat with a *differently named* hook in the workspace file — confirm merge (both run)
   rather than replace.
3. Repeat for `.agent/`, `_agents/`, `_agent/`.
4. Check whether the workspace file loads only for a **trusted** workspace
   (`antigravity-cli/settings.json` carries `trustedWorkspaces`, and a changelog string
   mentions reloading hooks when workspaces change). If trust gates it, that is a mitigation
   worth recording — but not a control, since the operator trusts their own repo.
5. Confirm whether `agy plugin install` can register hooks from
   `plugins/<name>/hooks.json`, and where those land on disk.

**If (1) blocks the guardrail, tamper coverage over all four workspace roots is mandatory in
T05 and must be in the tier-1 assertions.** If it cannot be covered, stop and re-spec.

---

## Phase 1 — Rule table, adapters, templates

### T04 — Split `deny-destructive.sh` into rules + adapters (D1)

Restructure, keeping Claude's behaviour bit-identical:

1. **Shared rule table** — the single source for `REQUIRED_DENY` (network tools, VCS
   mutations, installers, shell escapes), destructive envelopes (`find -delete`, `dd of=`,
   `mkfs`, `shred`, `truncate`, `git clean -fdx`), sensitive paths, tamper targets, and the
   `force_ask` set.
2. **Claude adapter** — existing parse (`tool_name`/`tool_input`), existing emit
   (`hookSpecificOutput`), **existing fail-open trap unchanged**.
3. **agy adapter** — parse `toolCall.name`/`toolCall.args`, emit `{"decision","reason"}`,
   **fail closed** per the T02 result.
4. Dispatch on tool name with an explicit `default:` that **denies** an unrecognised tool
   rather than passing it (F3).
5. Apply the sensitive-path list to `view_file.AbsolutePath`, `grep_search.SearchPath`, **and**
   `run_command.CommandLine` — three routes, one list (D4).
6. Tamper rules cover the engine dir, `claude-settings.json`, and every `hooks.json`
   discovery root from T03 — through write tools **and** shell redirection/`sed -i`/`tee`/`mv`
   in `run_command`.

Install path: `/usr/local/lib/sandbox-hooks/`. Keep
`/usr/local/lib/claude-hooks/deny-destructive.sh` working — Claude's seeded
`claude-settings.json` in every existing profile points at it, so this must not require a
profile reset to keep working.

### T05 — `sandbox_templates/antigravity/hooks.json`

```json
{
  "sandbox-guardrails": {
    "enabled": true,
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/usr/local/lib/sandbox-hooks/guardrails.sh --dialect=antigravity",
            "timeout": 2
          }
        ]
      }
    ]
  }
}
```

`"*"` not an enumerated regex (F3). Timeout per §5 of the spec — justify against the T02
answer and comment it in place. Absolute command path: cwd is `/root/.gemini/config`, a rw
bind mount, and must not be trusted.

### T06 — Tests

Extend `sandbox_templates/claude/hooks/deny-destructive.test.sh` (currently 113/113):

1. Claude dialect — all 113 existing cases still pass unchanged. This is the regression lock
   on the refactor.
2. agy dialect — one case per rule category, in agy envelope shape, asserting the agy output
   dialect.
3. **Fail-closed cases**: malformed JSON in, missing `toolCall`, unknown tool name, and a
   forced internal error each produce `{"decision":"deny",...}` — while the equivalent Claude
   inputs still produce the fail-open `{}`. The asymmetry is the whole point of D5 and is the
   assertion most likely to be "simplified" away later; comment it as a regression lock.
4. Tamper cases for each discovery root from T03, via both write tools and `run_command`.
5. Offline — no docker, no network.

Update the AGENTS.md contract paragraph with the new count.

---

## Phase 2 — Image and profile lifecycle

### T07 — Dockerfile

1. Bake the engine to `/usr/local/lib/sandbox-hooks/guardrails.sh`, mode `0755`.
2. Keep `/usr/local/lib/claude-hooks/deny-destructive.sh` functional (wrapper or symlink) so
   existing profiles' `claude-settings.json` keeps resolving.
3. Placement must respect the load-bearing layer order —
   `bash scripts/dockerfile-order.test.sh` (8/8).

### T08 — Seeding and convergence

`scripts/init-profile-state.sh` and `scripts/profile.sh::ensure_state`:

1. Ensure `$BASE/gemini-home/config` exists.
2. **File-scoped converge** of `hooks.json` only (D6). Do **not** mirror the directory —
   `config.json`, `mcp_config.json`, `projects/` and `.migrated` are live agy state (F7).
   Add the assertion to `scripts/profile-skills.test.sh` (or a sibling) so the mirror can
   never be introduced by someone generalising the skills converge.
3. `scripts/profile.sh <p> reset-antigravity`, mirroring `reset-settings` (`profile.sh:1348`).
4. No `*.bak*` beside the seeded file — same rule as the skills converge (ADR-0005).

---

## Phase 3 — Detectors

### T09 — Tier 1 (`scripts/verify-sandbox.sh`)

1. `/root/.gemini/config/hooks.json` present, non-empty, valid JSON, and matching the template.
2. `/usr/local/lib/sandbox-hooks/guardrails.sh` present, mode `0755`.
3. Behavioural, by piping envelopes to the engine:
   - `run_command: npm install` ⇒ `deny`
   - `run_command: find /tmp -delete` ⇒ `deny`
   - `view_file: /root/.gemini/antigravity-cli/antigravity-oauth-token` ⇒ `deny`
     (the real path — see spec §5)
   - `write_to_file` targeting a workspace `.agents/hooks.json` ⇒ `deny`
   - **malformed envelope ⇒ `deny`** (fail-closed tripwire)
4. Live agy state under `gemini-home/config/` still present — the D6 tripwire.

### T10 — Tier 2 (`scripts/audit/probes/antigravity.py`)

1. Live `hooks.json` presence and schema.
2. `enabled` is `true` and the matcher is `"*"`.
3. Live-vs-template diff.
4. No competing `hooks.json` in any mounted workspace's `.agents/` (surface, don't fail —
   a legitimate project hook is possible; an unexplained one is the signal).
5. Update the probe count in `README.md` and the audit docs.

### T11 — Upstream drift detector (D8)

Add to `just check-upstreams`, offline, following the `tools-check` pattern:

1. Assert every tool name in the engine's dispatch table still appears in the binary's
   embedded docs (`strings` — see spec §"How the [V] findings were verified").
2. Assert the decision enum (`allow|deny|ask|force_ask`) and the `PreToolUse` input keys are
   unchanged.
3. Three states, three outcomes, per AGENTS.md: nothing configured ⇒ loud `[SKIP]`, exit 0;
   configured but the binary is unreachable ⇒ **FAIL**; present ⇒ compare. A skip is not a
   pass, and it says so on the closing line.

---

## Phase 4 — Records and documentation

### T12 — ADR (D7)

`docs/adr/NNNN-antigravity-hook-only-policy.md`. Records: agy is hook-only where Claude is
two-layer; the two failure postures and why they differ; `force_ask` over `ask`; file-scoped
converge over mirror. Append-only — supersede, never delete.

### T13 — Docs

1. `ARCHITECTURE.md` — state layout and the second agent's policy layer.
2. `docs/permissions-model.md` — dual-agent enforcement.
3. `AGENTS.md` — add `sandbox_templates/antigravity/` and the engine to the
   security-sensitive list; update the hook test-suite contract line and the
   boundary-monitors section with the D8 detector.
4. `.agents/skills/profile-lifecycle.md` — `reset-antigravity`.
5. `sandbox_templates/common/agent-notice.md` — if agy denials need explaining to the agent,
   the notice is where it goes. Any edit there requires
   `bash scripts/agent-notice.test.sh` (13/13) and must name no repo-relative path and no
   host-side mechanism.
6. `work/README.md` — status.
