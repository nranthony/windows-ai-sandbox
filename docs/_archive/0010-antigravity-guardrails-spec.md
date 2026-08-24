# 0010 — Antigravity Tool Permissions and Pre-Tool Execution Hooks

**Status:** **Implemented** on `feat/0010-antigravity-guardrails` (2026-08-22). Phase 0 measured, all findings **[V]**, decisions revised where measurement contradicted them, recorded as [ADR-0006](../../docs/adr/0006-antigravity-is-two-layer-like-claude.md). Originally raised as **Draft — proposed.** Raised 2026-08-21 by owner request:
implement application-level tool policy and pre-tool execution lifecycle hooks for
**Antigravity (`agy`)** inside the sandbox, closing the gap against Claude Code's existing
posture (`claude-settings.json` + `deny-destructive.sh`). Phase 0 ran 2026-08-22; every finding below is now **[V]**, and three
decisions were reversed by what it found.

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

## 3. Findings — all measured 2026-08-22

Every finding below is now **[V]**. The method is the extraction command above;
where a claim came from running `agy` rather than reading its strings, the test
letter from Phase 0 is named.

### F1 [V] — the hook contract is as documented

`hooks.json` is an object of named hooks, each with `enabled` (default true) and
event arrays (`PreToolUse`, `PostToolUse`, `PreInvocation`, `PostInvocation`,
`Stop`). Tool-scoped events wrap handlers in `matcher` + `hooks`. A handler
takes `type` (`"command"` only), `command` (via `sh -c`, `~` expanded), and
`timeout` (default **30s**). Matchers are regexes on the tool name; `"*"`
matches all. Registration is visible in the log: `loaded N named hooks from M
hooks.json file(s)`.

`deny` blocks and the reason reaches the agent verbatim — *"Encountered error in
tool execution: tool call denied by pre-tool hook: `<reason>`"* (test A).

### F2 [V] — payload shape, plus fields the docs omit

Confirmed live. Beyond the documented keys, `run_command` also carries `Cwd`,
`RequestedTerminalID`, `RunPersistent`, `WaitMsBeforeAsync`, `toolAction` and
`toolSummary`. `workspacePaths` is `[]` unless a workspace is actually attached
(`--add-dir`), which matters — see F5.

Two behaviours that are NOT in the documentation and both changed the design:

- **`{}` is a DENY** (test E). An absent `decision` is not "no opinion"; the
  call is blocked with an empty reason. Claude's pass-through, reused here,
  would have blocked every tool call in the sandbox.
- **`allow` does not bypass the static permission layer** (test run 1). The hook
  allowed, and `agy` still refused for want of an allow-rule. So `allow` means
  "this hook has no objection", which is what makes it safe as a pass-through.

### F3 [V] — tool names, and the matcher decision reversed

`run_command` (`CommandLine`, `Cwd`), `write_to_file` (`TargetFile`,
`CodeContent`), `replace_file_content` (`TargetFile`, `ReplacementContent`),
`view_file` (`AbsolutePath`), `grep_search` (`SearchPath`).

The matcher is `"*"`, as planned. But the plan's companion rule — *an unmapped
tool must deny* — is **reversed**. With `"*"`, every `browser_*`, `mcp(...)`,
`search_web` and subagent call arrives at the hook; denying what the engine has
not been taught does not harden `agy`, it stops it working. Unmapped tools pass,
and completeness is the static list's job instead.

### F4 [V] — discovery and state placement

Priority, highest first: workspace `.agents/` (also `.agent/`, `_agents/`,
`_agent/`) → declared configs → global `~/.gemini/config/` → built-ins → global
declared. `$HOME` is honoured for all of it (verified with a scratch HOME).

`~/.gemini/config/hooks.json` is the right global home, corroborated by an `agy`
changelog string in the binary describing a fix that moved `/hooks` output there
from `antigravity-cli/hooks.json`. `gemini-home` is already bind-mounted, so
**zero compose changes**.

### F5 [V] — a workspace file disables the guardrail. Confirmed.

The finding this work turns on, and it reproduces exactly.

With the workspace attached (`agy --add-dir <ws>`) and
`<ws>/.agents/hooks.json` containing `{"sandbox-guardrails": {"enabled": false}}`,
`agy` logged `loaded 1 named hooks from 2 hooks.json file(s)` and the previously
denied command **ran** (exit 0, output produced) — test G.

Without a workspace attached the workspace file is not loaded at all (`1 file`,
still denied — test F). That is why the first attempt looked like a refutation:
`workspacePaths` was `[]`. A negative result here depends on a condition the
tester controls, which is worth remembering the next time one of these looks
clean.

Consequences, all now implemented:

- The hard denials moved to `permissions.deny` in `settings.json`, which no
  workspace customization can reach. This is the layer that must be complete.
- The hook blocks writes to all four workspace `hooks.json` names, through the
  write tools **and** the shell route (`>`, `tee`, `sed`, `cp`, `mv`, `mkdir`).
- Tier-1 verify scans `/workspace` for one; the tier-2 probe reports DRIFT.

`agy plugin install` remains a second, unexamined route to registered hooks
(`plugins/<name>/hooks.json`). Recorded, not closed.

### F6 [V] — `agy` fails CLOSED. The concern was real but inverted.

Four handlers, four runs (test B/C/D and E):

| Handler | Outcome |
|---|---|
| `exit 1`, no stdout | **blocked** — `JSON hook … failed: command failed: exit status 1` |
| prints `not json` | **blocked** — `failed to unmarshal result from hook … via protojson` |
| `sleep 30` with `"timeout": 2` | **blocked** — `command failed: signal: killed` |
| prints `{}` | **blocked** — `tool call denied by pre-tool hook:` (empty reason) |

So the harness is fail-closed whatever the script does, and the risk runs the
other way: a permanently broken hook makes `agy` unable to run any tool. The
engine therefore catches its own errors and emits an explicit deny with a
readable reason, rather than relying on crashing.

`--dangerously-skip-permissions` was **not** re-tested against hook execution;
it is out of scope per §1 and remains the one open question. Headless mode
auto-denies anything needing a prompt, which is why the seeded `allow` list
makes `agy -p` more usable, not less.

### F7 [V] — `gemini-home/config/` is not empty

Observed on `fluidmomenta`: `.migrated`, `config.json` (0600, live —
`userSettings.remoteControlHostname`), `mcp_config.json`, `projects/`. ADR-0005
mirror semantics here would delete all four. Convergence is file-scoped and the
suite locks it.

### F8 [V] — NEW: `agy` has a static permission layer, and the spec's premise was wrong

Not in the original spec at all, and it reshaped the design.

`/root/.gemini/antigravity-cli/settings.json` accepts:

```json
{ "permissions": { "allow": [...], "ask": [...], "deny": [...] },
  "toolPermission": "request-review" }
```

Parsed struct visible in the log as `permissions=&{Allow:[…] Deny:[…] Ask:[…]},
toolPermission=…`. Grants are `command(<prefix>)`, prefix-matched (*"'git'
matches 'git add', 'git commit'"*). A denied command reports *"Permission denied
for command(echo hello-probe). Matches user-configured deny rule."* (test H).

Modes: `always-proceed`, `request-review` (default), `strict`,
`proceed-in-sandbox`.

Locating it took three wrong guesses — it is **not** in `config/config.json`,
which the startup log mentions (`no shared config permissions from …`) and which
in practice holds only `userSettings`. The error text `Add an allow-rule under
permissions.allow in settings.json` was the thing that pointed at the right file.

The template tolerates `_comment` keys (verified by parsing it with `agy`), but
not `//` comments — unlike `claude-settings.json`. The parity suite locks that.

Other action kinds exist (*"Matches the file or everything under the
directory"*, *"Matches the domain and all subdomains"*, *"Matches by exact
server name"*) but their grant syntax was not established. Secret-file reads are
enforced by the hook instead; see ADR-0006 Consequences.

## 4. Architectural Decisions — as built

Three of the original eight were **reversed by measurement**, and two are new.
Reversals and additions are marked ⟲.

| # | Decision | As built | Rationale |
|---|---|---|---|
| **D1** | Engine shape | **Shared rule table, thin per-dialect adapters.** The `agy` envelope is translated into the Claude shape immediately after reading, so every rule below the adapter is shared. Only input translation, output emission and failure posture are dialect-specific. | Drift between two hand-maintained rule sets is the failure to prevent; one table prevents it. Sharing the *script* wholesale would force one failure posture on two layers that need opposite ones. |
| **D2** | Deployment | **Converge on `up`**, file-scoped and merging. | ADR-0005's reasoning; see D6 for why merge and not mirror. |
| **D3** ⟲ | Gated writes | **Static `ask` list now; `force_ask` via the hook is follow-up, NOT built.** | The review's point stands — `ask` honours the Always-Allow cache and Claude's re-prompts. But `force_ask` is a *hook* decision while Claude expresses this set statically, so wiring it adds a decision type to the shared table that only one dialect emits. Recorded as a known asymmetry in ADR-0006 rather than half-built. |
| **D4** | Sensitive reads | **One path list applied to `view_file`, `grep_search` and `run_command`.** | Three routes to the same bytes. In the hook because the static file-grant grammar was not established (F8). |
| **D5** ⟲ | Failure posture | **Claude fail-open, antigravity fail-closed — right answer, opposite reason.** | F6: `agy` is already fail-closed at the harness level. The adapter does not manufacture a deny by crashing; it catches its own errors and emits an explicit one, so the operator sees a reason instead of a protojson parse error. |
| **D6** | Converge granularity | **File-scoped, and `settings.json` merged key-by-key.** | F7 plus F8: `settings.json` is shared with the running agent, so even file-scoped *replacement* would discard `colorScheme`/`model`/`trustedWorkspaces`. |
| **D7** | Provenance tier | **ADR-0006 landed.** | ADR-0001: security boundary + cross-agent convention. |
| **D8** ⟲ | Upstream drift | **Tier-1 verify, not `just check-upstreams`.** | The comparison target is inside the image (`agy` embeds its own docs); check-upstreams is offline by contract and reads sibling checkouts, never docker. `agy` is also not a *vendored* payload — it is fetched at build time — so the "detector belongs with the stale copy" rule points at verify. |
| **D9** ⟲ | **NEW — which layer is load-bearing** | **The static `permissions.deny` carries the hard denials; the hook is defence-in-depth.** | F5 + F8, and the most consequential change. The spec assumed hooks were the only mechanism available to `agy`. They are the *bypassable* one. |
| **D10** ⟲ | **NEW — unmapped tools** | **Pass, do not deny.** | F3. The pre-measurement plan said deny; with matcher `"*"` that stops `agy` working rather than hardening it, and completeness belongs to the static list anyway. |

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

## 6. Definition of Done — status

| # | Item | State |
|---|---|---|
| 1 | F5/F6 answered empirically and written back | **done** — §3, all `[V]` |
| 2 | Templates seeded by a file-scoped converge | **done** — `sandbox_templates/antigravity/`, `converge_antigravity` |
| 3 | Shared rule table + per-dialect adapters, both green offline | **done** — 136/136 |
| 4 | Tamper coverage over every discovery root, write tools **and** shell | **done** — `agy-workspace-hook-tamper`, both routes |
| 5 | Tier-1 asserts presence, mode, behaviour, and fail-closed | **done** — `scripts/verify-sandbox.sh` |
| 6 | Tier-2 probe reports OK | **done** — `scripts/audit/probes/antigravity.py`, registered in `aggregate.py` |
| 7 | Drift detector wired | **done** — tier-1 verify (D8) |
| 8 | ADR landed | **done** — ADR-0006 |
| 9 | `just test-offline` green; docs updated | **done** — eight suites (136/38/66/8/24/57/13/28); README, ARCHITECTURE, permissions-model, AGENTS.md, profile-lifecycle |

**Deliberately not done:**

- **`force_ask` for the mutating `myclickup` set** (D3). Static `ask` is in
  place; the cache asymmetry is documented in ADR-0006.
- **`agy`'s file-grant syntax.** Secret reads therefore sit in the hook — the
  layer a workspace file can disable. Commands are unaffected.
- **`agy plugin install` as a hook-injection route.** Identified in F5, not
  examined.
- **Behaviour under `--dangerously-skip-permissions`.** Out of scope per §1, and
  the one Phase 0 question left unanswered.

**Not yet verified in a built image.** Everything is proven offline, plus a live
end-to-end run against real `agy` with the engine hand-placed into a running
container: `npm install` was refused by the static list and `find /tmp -delete`
by the hook, and the agent reported each as a human step. But the image has
**not** been rebuilt, so `/usr/local/lib/sandbox-hooks/guardrails.sh` does not
exist in it. Order matters — `just build`, then `up` (or `reset-antigravity`). A
`hooks.json` naming a missing engine leaves `agy` unguarded without saying so;
tier-1 verify is the check that catches it.
