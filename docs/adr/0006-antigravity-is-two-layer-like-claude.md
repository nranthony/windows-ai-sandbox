# ADR-0006 — Antigravity gets the same two-layer policy as Claude Code, and the static layer is the load-bearing one

- **Status:** Accepted
- **Date:** 2026-08-22
- **Supersedes:** nothing. Establishes the `agy` half of the application-level
  policy that `sandbox_templates/claude/` has carried since 2026-06.
- **Affects:** `Dockerfile`, `scripts/profile.sh` (`ensure_state`,
  `converge_antigravity`, `reset-antigravity`), `scripts/init-profile-state.sh`,
  `scripts/verify-sandbox.sh`, `scripts/audit/probes/antigravity.py`,
  `sandbox_templates/antigravity/`,
  `sandbox_templates/claude/hooks/deny-destructive.sh` (now shared by both
  agents), and `work/0010`.

## Context

Claude Code runs inside this sandbox under three layers: the system boundary
(rootless Docker, seccomp, `cap_drop ALL`, Squid egress), a static tool policy
(`permissions.allow/ask/deny` in `claude-settings.json`), and a `PreToolUse`
hook (`deny-destructive.sh`) for the envelope patterns a prefix matcher cannot
see. Antigravity (`agy`) had only the first.

`work/0010` was specified before any of `agy`'s behaviour had been measured, and
the specification was wrong in three ways that each changed the design. All
three were settled empirically against the shipped binary — which embeds its own
customization and hooks documentation as literal strings, so the contract can be
read out of it directly:

```bash
docker exec ai-sandbox-<profile> sh -c 'strings -n 6 /usr/local/bin/agy' > /tmp/agystr.txt
grep -n "PreToolUse\|hooks.json\|Customization Discovery" /tmp/agystr.txt
```

### What measurement changed

**1. `agy` already has a static permission layer.** The original premise —
"Antigravity has no application-level tool permissions, so hooks are the only
option" — is false. `/root/.gemini/antigravity-cli/settings.json` accepts

```json
{ "permissions": { "allow": [...], "ask": [...], "deny": [...] },
  "toolPermission": "request-review" }
```

with grants of the form `command(<prefix>)`, prefix-matched exactly as Claude's
`Bash(x:*)` is. A denied command reports *"Permission denied for
command(echo hello-probe). Matches user-configured deny rule."* This is a
structural twin of `claude-settings.json`, and it was there all along.

The related over-claim in the original problem statement is also corrected:
`agy` does **not** run unprompted. `--dangerously-skip-permissions` exists
precisely because prompting is the default. The real gap was that the human was
the *only* gate, that an "Always Allow" grant is sticky, and that a denial
taught the agent nothing.

**2. A workspace file can switch the hook off.** `agy` discovers customizations
under `.agents/`, `.agent/`, `_agents/` and `_agent/`, merges hooks **by name**,
and lets the workspace copy outrank the global one. With a workspace attached,
a file containing

```json
{ "sandbox-guardrails": { "enabled": false } }
```

disarmed the global guardrail outright — `agy` logged `loaded 1 named hooks from
2 hooks.json file(s)` and the previously denied command ran. `/workspace` is the
agent's own writable bind mount; this needs no privilege whatsoever.

Nothing in a workspace can reach `settings.json`.

**3. The failure posture is the opposite of what was assumed.** The concern was
that `deny-destructive.sh` is deliberately fail-open and that sharing it would
carry fail-open into a position where it meant no enforcement. Measured, `agy`
is fail-**closed** at the harness level: a hook that exits non-zero, times out,
or prints unparseable stdout blocks the tool call. And `{}` — Claude's
pass-through — is a **deny** to `agy`, because an absent `decision` is not
"no opinion".

## Decision

**1. Two layers for `agy`, mirroring Claude, with the static list carrying the
hard denials.** `permissions.deny` in `antigravity-settings.json` holds the 85
command prefixes; the hook holds the envelope rules (destructive flags, path
targets, tamper protection, secret reads). The hard denials go in the layer a
workspace cannot reach — the inversion of the pre-measurement plan, which put
everything in the hook.

**2. One rule table, two thin adapters — not two scripts, and not one
undifferentiated script.** `deny-destructive.sh` translates the `agy` envelope
into the Claude shape immediately after reading it, so every rule below the
adapter is shared and a rule added for one agent protects both. Only three
things are dialect-specific: input translation, output emission, and failure
posture.

**3. The failure postures stay different, deliberately.** Claude fails open (its
static list is underneath it). Antigravity fails closed (for reads the hook *is*
the control, and `agy` blocks a misbehaving hook anyway). Pass-through under
`agy` is an explicit `{"decision":"allow"}`, never `{}`. `allow` does not bypass
`agy`'s own permission check — also measured — so it means "this hook has no
objection", not "auto-approve".

**4. The matcher is `"*"`, and an unmapped tool passes.** `agy` self-updates and
its tool surface is large and moving; an enumerated matcher stops matching a
renamed tool in silence. Denying every unmapped tool does not harden the agent,
it stops it working — which is why completeness is the static list's job.

**5. Convergence, not create-only (ADR-0005's reasoning), but file-scoped and
merging.** `hooks.json` is replaced wholesale. `antigravity-cli/settings.json`
is **merged** — only `permissions` and `toolPermission` are written, because
`agy` stores `colorScheme`, `model`, `enableTelemetry` and `trustedWorkspaces`
in that same file. And `gemini-home/config/` is never mirrored: it already holds
`config.json`, `mcp_config.json`, `.migrated` and `projects/`, all live `agy`
state that ADR-0005's mirror semantics would delete on a routine `up`.

## Consequences

- Two static deny lists now say the same thing in two grammars.
  `scripts/antigravity-parity.test.sh` diffs them exactly, in both directions,
  with no exception list — an exception list is where drift hides. Add a command
  to both files or to neither.
- `deny-destructive.sh` is now security-critical for two agents. Its test suite
  grew to 136 and asserts the two failure postures *differ*; that asymmetry is
  the assertion most likely to be "cleaned up" into a hole.
- `just reset-antigravity <profile>` before `just build` leaves a `hooks.json`
  pointing at an engine the image does not yet contain. `agy` treats a missing
  hook command as nothing to run and carries on **unguarded**, so this fails
  silently. Tier-1 verify asserts `engine_present`; the ordering is build first.
- `agy`'s `ask` caches an approval as an Always-Allow grant, unlike Claude's
  `permissions.ask` which re-prompts. The mutating `myclickup` set is therefore
  weaker under `agy` than under Claude. The hook can emit `force_ask`, which
  ignores that cache; wiring the mutating set through it is deliberately left
  as follow-up rather than half-built here.
- File-grant syntax for `agy` (the non-`command()` action kinds implied by
  *"Matches the file or everything under the directory"*) was not reverse
  engineered. Secret reads are enforced by the hook instead, across `view_file`,
  `grep_search` and `run_command` alike. If the file-grant grammar is ever
  established, those reads should move down to the static layer for the same
  tamper-resistance reason as the commands.
- The hook contract is an upstream API on a self-updating binary. Tier-1 verify
  asserts the five dispatched tool names and the decision enum still appear in
  the shipped binary. It lives in verify rather than `just check-upstreams`
  because the thing to compare against is inside the image, and check-upstreams
  is offline by contract.
