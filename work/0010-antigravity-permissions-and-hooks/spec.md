# 0010 — Antigravity Tool Permissions and Pre-Tool Execution Hooks

**Status:** **Draft — proposed.** Raised 2026-08-21 by owner request:
implement application-level tool policy and pre-tool execution lifecycle hooks for
**Antigravity (`agy`)** inside the sandbox, closing the gap against Claude Code's existing
posture (`claude-settings.json` + `deny-destructive.sh`). Reviewed 2026-08-22 — findings
below are now marked **[V]** verified or **[?]** open; the open ones gate Phase 1.

**Shelf life:** Delete this folder, or move to [`docs/_archive/`](../../docs/_archive/),
when the work merges.

**Security-sensitive.** The change touches `Dockerfile`, `scripts/profile.sh`,
`scripts/init-profile-state.sh`, `scripts/verify-sandbox.sh`, `sandbox_templates/`, and adds
new audit probe modules. Every commit needs a `SECURITY IMPACT` line,
`scripts/profile.sh <p> verify` (tier 1) green, and `scripts/profile.sh <p> audit` (tier 2)
run — see [AGENTS.md](../../AGENTS.md). `just test-offline` before calling it done.
Per [ADR-0001](../../docs/adr/0001-provenance-tiers.md) this touches the security boundary
and a cross-agent convention, so it also lands an **ADR** (see §6, D7).

### How the [V] findings were verified

The `agy` binary embeds its own customization and hooks documentation as literal strings.
Everything marked **[V]** was read out of the shipped binary, not from external docs:

```bash
docker exec ai-sandbox-<profile> sh -c 'strings -n 6 /usr/local/bin/agy' > /tmp/agystr.txt
grep -n "PreToolUse\|hooks.json\|Customization Discovery" /tmp/agystr.txt
```

Re-run this after any `agy` update — the contract is an upstream API on a self-updating
binary, which is the whole argument for D8 (drift detector).

---

## 0. Context and Problem Statement

In the current sandbox architecture, **Claude Code** is constrained by multiple defence-in-depth layers:

1. **System boundaries**: Rootless Docker (`UID 0 ↔ Host 1000`), `cap_drop ALL`,
   `no-new-privileges`, strict default-deny `seccomp.json`, `noexec` on `/tmp` and
   `/root/.local`, and Squid egress allowlisting (`proxy/allowed_domains.txt`).
2. **Application-level tool policy**: `sandbox_templates/claude/claude-settings.json` defines
   explicit `allow` (read-only tools, safe git), `ask` (mutating `myclickup` subcommands), and
   `deny` (50+ patterns: network tools, package installers, shell escapes, destructive
   commands, sensitive file reads).
3. **Pre-tool execution hooks**: `deny-destructive.sh` runs before `Bash` and `Edit`/`Write`,
   matching regexes on the full command envelope to intercept what the prefix matcher cannot
   see (`find -delete`, `dd of=`, `git clean -fdx`, `mkfs`, hook/settings tampering).

**Antigravity (`agy`) has layer 1 and contextual markdown (`AGENTS.md`, `agent-notice.md`),
but no layer 2 and no layer 3.**

### The gap, stated accurately

An earlier draft of this spec claimed agy "allows in-container command execution to proceed
unprompted". **That is wrong and the correction matters**, because it changes what this work
is buying. `agy --help` documents `--dangerously-skip-permissions` as *"Auto-approve all tool
permission requests without prompting"* — which means **prompting is the default**. agy does
gate tool calls interactively.

The real gap is narrower, and still sufficient to justify the work:

- **No policy layer.** The human operator is the *only* gate. There is no deny list, so
  nothing is unconditionally refused — every dangerous action is one keypress from running,
  and the keypress arrives with no context about why it is dangerous.
- **Approvals are sticky.** agy caches "Always Allow" grants per workspace and persists them
  (`failed to write permission grant`, `failed to add allowed CEL expression` in the binary).
  One approval of `npm install` is a standing approval.
- **The gate can be removed wholesale.** `--dangerously-skip-permissions` disables it
  entirely; nothing in the sandbox currently prevents or detects that invocation.
- **Denials carry no teaching.** Claude's deny list is also documentation — the reason string
  tells the agent to route installs through `with-egress.sh` and to treat a denial as a human
  step (`sandbox_templates/common/agent-notice.md`). agy gets none of that.

So the objective is not "add a gate where there is none" but **"replace an unconditional
human prompt with a policy that hard-denies the unsafe set, force-prompts the mutating set,
and explains itself"**.

---

## 1. Scope

**In:**
- An Antigravity customization template under `sandbox_templates/antigravity/`.
- A global `hooks.json` registering a `PreToolUse` handler.
- A policy engine sharing Claude's rule table but with a **per-dialect adapter** (D1) and an
  **agy-specific failure posture** (D5).
- Seeding and converging `hooks.json` into `gemini-home/config/hooks.json` — **file-level, not
  a directory mirror** (D6, F7).
- `scripts/profile.sh <profile> reset-antigravity`.
- Tier-1 assertions in `scripts/verify-sandbox.sh`; a tier-2 probe
  `scripts/audit/probes/antigravity.py`.
- Tamper coverage for **every** hook-config discovery location, not just the global one (F5).
- An upstream-contract drift detector (D8).
- Test suites; an ADR.

**Out:**
- Modifying the `agy` binary or CLI internals.
- Interactive TUI customisation.
- System-level boundaries (seccomp, compose mounts, squid allowlist).
- **Blocking `--dangerously-skip-permissions` itself.** Detecting or preventing that
  invocation is a separate concern (it is a host-side/attach-side question, not a hook
  question) — but F6/§5 record whether hooks still fire under it, because if they do not,
  this entire design is advisory for headless runs.

---

## 2. Parity Model: Claude Code vs. Antigravity

| Guardrail Layer | Claude Code Mechanism | Antigravity Mechanism (Target) |
|---|---|---|
| **Config Location** | `/root/.claude/settings.json` | `/root/.gemini/config/hooks.json` (profile `gemini-home/config/`) |
| **Tool Matcher** | Prefix matching (`Bash(cmd:*)`, `Read(path)`) | `PreToolUse` matcher regex — **`"*"` with in-script dispatch**, not an enumerated list (F3) |
| **Deny Categories** | `permissions.deny` in `settings.json` | Hook inspects `toolCall.name` / `toolCall.args`, returns `{"decision":"deny","reason":"..."}` |
| **Gated Writes** | `permissions.ask` | `{"decision":"force_ask"}` — **not `ask`**, which honours the Always-Allow cache (D3) |
| **Destructive Envelopes** | `deny-destructive.sh` regexes | Same shared rule table, agy adapter |
| **Tamper Protection** | Blocks writes to `claude-settings.json` and `/usr/local/lib/claude-hooks/` | Blocks writes to the engine dir **and every hooks.json discovery root** (F5) |
| **Failure Posture** | **Fail-open** by design — `permissions.deny` is the primary layer | **Fail-closed** — the hook is the *only* layer (D5, F6) |
| **Lifecycle Seeding** | `init-profile-state.sh` + `ensure_state` → `claude-home/settings.json` | Same → `gemini-home/config/hooks.json`, **file-level converge** (D6) |
| **Tripwires / Audits** | `verify-sandbox.sh` + `scripts/audit/probes/settings.py` | `verify-sandbox.sh` + `scripts/audit/probes/antigravity.py` |

---

## 3. Findings

### F1 [V] — Antigravity uses one lifecycle-hook mechanism for both policy and safety

Claude splits enforcement across static prefix matching (`claude-settings.json`) and dynamic
envelope inspection (`deny-destructive.sh`). agy has only the dynamic half: a `PreToolUse`
handler declared in `hooks.json`, which can return `allow`, `deny`, `ask`, or `force_ask`.

`hooks.json` is a JSON object whose top-level keys are **hook names**; each maps to event
arrays (`PreToolUse`, `PostToolUse`, `PreInvocation`, `PostInvocation`, `Stop`). Tool-scoped
events wrap handlers in a `matcher` + `hooks` group. A hook spec accepts `enabled` (default
`true`). A handler accepts `type` (only `"command"`), `command` (required, run via `sh -c`,
`~` expanded), and `timeout` (seconds, **upstream default 30**).

Matchers are regexes over the tool name: `"*"` or `""` matches all, `"run_command"` exactly,
`"browser_.*"` by prefix. Tool names are the step type lowercased with the
`CORTEX_STEP_TYPE_` prefix stripped.

**Multiple named hooks for the same event are merged and executed sequentially.** That
merge behaviour is what makes F5 dangerous.

### F2 [V] — Input / output schema

Claude's hook receives `{"tool_name": "Bash", "tool_input": {"command": "..."}}` and returns
`{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"..."}}`.

Antigravity's `PreToolUse` receives (all keys camelCase protojson):

```json
{
  "toolCall": { "name": "run_command", "args": { "CommandLine": "find /tmp -delete" } },
  "stepIdx": 19,
  "conversationId": "ec33ebf9-...",
  "workspacePaths": ["/workspace/repo"],
  "transcriptPath": "/workspace/repo/.gemini/antigravity-cli/transcript.jsonl",
  "artifactDirectoryPath": "...",
  "modelName": "auto"
}
```

and returns:

```json
{ "decision": "deny", "reason": "..." }
```

- `decision` (required): `allow` (auto-allow), `deny` (hard block), `ask` (prompt,
  **respects the Always-Allow cache**), `force_ask` (always prompt, ignores the cache).
- `reason` (optional): shown to user and agent.
- `permissionOverrides` (optional, array): temporary grants.
- `overwrite` (optional, object): **shallow top-level merge into the tool call's arguments
  before it runs**. The rewritten call is what executes and is recorded.

`overwrite` is not in scope as a feature, but it is a capability of the hook interface and
therefore of anything that can write `hooks.json` — a second reason F5's tamper coverage
must be complete. A hostile hook does not have to allow a command; it can silently rewrite it.

### F3 [V] — Tool names, and why the matcher should be `"*"`

Relevant tools: `run_command` (`CommandLine`, `Cwd`), `write_to_file` (`TargetFile`,
`CodeContent`), `replace_file_content` (`TargetFile`, `TargetContent`, `ReplacementContent`),
`view_file` (`AbsolutePath`), `grep_search` (`SearchPath`).

The earlier draft enumerated four of these in the matcher regex and omitted `grep_search`,
which its own finding listed as a read path. That is the failure mode to design against:
**agy self-updates** (`scripts/profile.sh:90` — "agy still refreshes to latest"), so a tool
that is renamed or added upstream silently stops matching and the miss is invisible.

Use `"matcher": "*"` and dispatch on `toolCall.name` inside the engine, with an explicit
`default:` branch. An unrecognised tool name is a tool the engine has not been taught — the
same argument that makes `vendor-tools.sh` fail on an unknown artifact kind rather than skip it.

Note also that read denial is not a `view_file` problem. `run_command: cat .env`,
`grep_search` over a secret path, and `view_file` are three routes to the same bytes; the
sensitive-path rule set must be applied to all of them from one list.

### F4 [V] — Config discovery and state placement

Discovery locations, highest priority first:

1. **Workspace**: `.agents/` (also `.agent/`, `_agents/`, `_agent/`) — walked from CWD up to
   the repo root.
2. **Declared**: `skills.json` / `plugins.json` in the workspace.
3. **Global**: `~/.gemini/config/`.
4. **Built-in**: bundled defaults.
5. **Global declared**.

`~/.gemini/config/hooks.json` is therefore the correct global home, confirmed independently
by an agy changelog string in the binary: the `/hooks` command *"wrote configurations to
`~/.gemini/antigravity-cli/hooks.json` instead of the shared `~/.gemini/config/hooks.json`"*
and was fixed.

`${HOME}/.ai-sandbox/profiles/<profile>/gemini-home` is already bind-mounted to `/root/.gemini`
(`docker-compose.yml:72`), so seeding needs **zero compose changes**. (The host dir is named
`gemini-home` for historical reasons — former Gemini CLI mount — and the compose comment
already records that. The template dir is named `antigravity/` after the product; the
mismatch is deliberate and gets a comment at both ends.)

### F5 [?] — Workspace `.agents/hooks.json` is a documented override path

This is the finding that most affects the design and it is **not yet empirically confirmed**.

From F1 and F4 together: hooks merge **by name**, and *"if there are naming conflicts, the
higher-priority customization overrides the lower-priority one"*, with workspace above global.
So a file the agent can create with no privilege at all —

```json
{ "sandbox-guardrails": { "enabled": false } }
```

— written to `/workspace/<repo>/.agents/hooks.json` may disable the guardrail outright.
`/workspace` is a rw bind mount of the user's own repo; writing a dotfile there is an ordinary
action requiring nothing special.

If confirmed, consequences:

- Tamper protection must cover writes **and shell writes** (`cat >`, `sed -i`, `tee`,
  redirection, `mv`) targeting `**/.agents/hooks.json`, `**/.agent/hooks.json`,
  `**/_agents/hooks.json`, `**/_agent/hooks.json`, plus `skills.json` / `plugins.json`.
- `agy plugin install` is a real subcommand, and plugin bundles register their own
  `plugins/<name>/hooks.json`. That is a second injection route and currently unscoped.
- A hook name that is trivially guessable makes the attack a one-liner. Naming is not a
  control, but there is no reason to hand it over either.

**Do not begin T02 until this is tested.** If it holds and cannot be covered, the hook-only
design is not sound and this spec needs a different answer.

### F6 [?] — Fail-open cannot be inherited

`deny-destructive.sh:16` states the fail-open choice explicitly: *"a broken hook must not brick
the agent"*, safe **because** `permissions.deny` is the primary layer and the hook is
defence-in-depth on top of it. The mechanism is
`trap 'printf "{}\n"; exit 0' EXIT INT HUP TERM`.

For agy there is no `permissions.deny`. The hook is the entire policy layer. Sharing the
script as-is (the earlier D1) silently moves a deliberate fail-open into a position where it
means **no enforcement at all** on any script error — a missing `jq`, a malformed envelope, an
unhandled `set -u`.

Open questions, all of which need answering empirically:

1. What does agy do when a `PreToolUse` handler **times out**? Allow, deny, or prompt?
2. What does it do on a **non-zero exit**?
3. What does it do on **non-JSON stdout**, empty stdout, or a missing `decision` key?
   (Claude's pass-through is a bare `{}`; agy's `decision` is documented as *required*.)
4. Does the handler run at all under **`--dangerously-skip-permissions`**?

(1)–(3) decide whether "fail-closed" is even expressible: if agy treats a broken hook as
allow, the engine cannot fail closed by crashing — it must catch its own errors and emit an
explicit `deny`. (4) decides whether any of this binds in headless use.

### F7 [?→V] — `gemini-home/config/` is not empty

Observed on a live profile (`fluidmomenta`):

```
gemini-home/config/
├── .migrated
├── config.json          (0600, live)
├── mcp_config.json
└── projects/
```

ADR-0005 convergence **mirrors**: a file absent from the template is deleted from the profile.
That is correct for skills and catastrophic here — mirroring a one-file template over this
directory deletes agy's MCP config and project state. Convergence must be **file-scoped**
(D6), and the test suite must lock it, because the failure is silent data loss on a routine
`up`.

---

## 4. Architectural Decisions

| # | Decision | Recommendation | Rationale |
|---|---|---|---|
| **D1** | **Engine shape**: one shared script vs. shared rules + per-dialect adapters | **Shared rule table, thin per-dialect adapters.** One rule source; separate `parse` / `emit` / failure-posture per dialect. | Rule drift between the two agents is the thing to prevent, and a shared table prevents it. Sharing the *script* does not follow: it puts every edit to a 332-line security script in the path of two agents at once, and it forces one failure posture on two layers that need opposite ones (F6). The `trap` line is precisely what must not be shared. |
| **D2** | **Deployment**: create-only vs. converge on `up` | **Converge on `up`** ([ADR-0005](../../docs/adr/0005-skill-templates-are-source-of-truth.md)). | Security guardrails must not lag the template. `reset-antigravity` for manual re-sync. |
| **D3** | **Gated writes**: `ask` vs. `force_ask` | **`force_ask`.** | F2: `ask` honours the Always-Allow cache, so a `myclickup create` approved once is approved forever. Claude's `permissions.ask` re-prompts every time; `force_ask` is the primitive that matches it. Using `ask` would be parity in name only. |
| **D4** | **Sensitive reads** | **Yes — one path list, applied to `view_file`, `grep_search`, and `run_command`.** | F3: three routes to the same bytes. Deny `.env`, `*.pem`, `*.key`, `id_rsa*`, `.credentials*`, and the real agy token path (§5). |
| **D5** | **Failure posture** | **agy adapter fails CLOSED; Claude adapter keeps fail-open.** The agy adapter wraps its own body, catches any error, and emits an explicit `{"decision":"deny","reason":"guardrails: internal error"}`. | F6. Fail-open is correct for a second layer and wrong for a only layer. Making the difference explicit and per-adapter is the point of D1. Exact mechanism depends on F6(1)–(3). |
| **D6** | **Converge granularity** | **File-scoped converge of `hooks.json` only.** Never mirror `gemini-home/config/`. | F7 — a directory mirror deletes live `config.json`, `mcp_config.json`, and `projects/`. Locked by a test. |
| **D7** | **Provenance tier** | **ADR.** | [ADR-0001](../../docs/adr/0001-provenance-tiers.md): security boundary + cross-agent convention. Records why agy is hook-only where Claude is two-layer, and why the failure postures differ. |
| **D8** | **Upstream drift** | **A detector, wired into `just check-upstreams`.** | AGENTS.md: *the detector belongs on the side that owns the stale copy.* `agy` self-updates and its hook contract is an upstream API — a renamed tool or a changed decision enum disarms the guardrail while every suite stays green. Minimum viable: a tier-1 behavioural check that runs a real denial through `agy`, plus an assertion that the tool names the engine dispatches on still appear in the binary's embedded docs. |

---

## 5. Corrections to carry into implementation

Small factual fixes from the review, recorded so they do not get re-introduced:

- **The agy secret is `/root/.gemini/antigravity-cli/antigravity-oauth-token`** (0600). The
  earlier draft's verify assertion named `/root/.gemini/gemini-home/oauth_creds.json`, which
  does not exist — a tripwire on a nonexistent path passes for the wrong reason.
- **Hook cwd is the directory containing `hooks.json`** = `/root/.gemini/config`, a rw bind
  mount. The engine must be invoked by absolute path and must not rely on cwd.
- **Timeout**: Claude's handler uses `2`; upstream default is `30`. Pick one value, state why,
  and tie it to the F6(1) answer — a timeout that fails open is a bypass with a stopwatch.
- **AGENTS.md carries the test-suite contract line** (`deny-destructive.test.sh` … 113/113).
  Growing the suite means updating that paragraph, the `just test-offline` wiring, and the
  probe count in `README.md`.

---

## 6. Definition of Done

1. **F5 and F6 answered empirically and written back into this spec** before any engine code.
2. `sandbox_templates/antigravity/hooks.json` authored and seeded to
   `gemini-home/config/hooks.json` by a file-scoped converge (D6).
3. Shared rule table + per-dialect adapters (D1), agy adapter fail-closed (D5), both dialects
   green offline.
4. Tamper coverage over every discovery root from F4/F5, via write tools **and** `run_command`.
5. `scripts/profile.sh <p> verify` (tier 1) asserts hook presence, engine mode `0755`, and
   behavioural blocks — including a **fail-closed** case (malformed envelope ⇒ `deny`).
6. `scripts/audit/probes/antigravity.py` (tier 2) reports `OK`; probe count updated.
7. Drift detector (D8) wired into `just check-upstreams`.
8. ADR landed (D7).
9. `just test-offline` green; `README.md`, `ARCHITECTURE.md`,
   [`docs/permissions-model.md`](../../docs/permissions-model.md), `AGENTS.md`, and
   `.agents/skills/profile-lifecycle.md` updated.
