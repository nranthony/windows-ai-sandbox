# `sandbox_templates/antigravity/`

The Antigravity (`agy`) half of the sandbox's application-level policy. Both
files are seeded and converged by `scripts/profile.sh` on every `up`; neither
requires a change to `docker-compose.yml`, because
`~/.ai-sandbox/profiles/<profile>/gemini-home` is already bind-mounted to
`/root/.gemini`.

| Template | Lands at | Converge mode |
|---|---|---|
| `hooks.json` | `/root/.gemini/config/hooks.json` | whole file, overwritten |
| `antigravity-settings.json` | `/root/.gemini/antigravity-cli/settings.json` | **merged** — see below |

## Why the two files are not converged the same way

`hooks.json` is ours alone: nothing but the sandbox writes it, so it is
replaced wholesale.

`antigravity-cli/settings.json` is **shared with the running agent**. `agy`
writes `colorScheme`, `model`, `enableTelemetry` and `trustedWorkspaces` back
into it during ordinary use. Overwriting it would silently discard the user's
own settings on every `up`, so convergence merges only the two keys the
sandbox owns — `permissions` and `toolPermission` — and leaves every other key
untouched.

The same reasoning applies one level up: `gemini-home/config/` already holds
`config.json`, `mcp_config.json`, `.migrated` and `projects/`, which are live
`agy` state. Convergence there is **file-scoped**, never the directory mirror
used for skills (ADR-0005) — a mirror would delete all four.

## Why the hard denials live in settings.json, not in the hook

Measured, not assumed (`work/0010` Phase 0). `agy` discovers workspace
customizations under `.agents/`, `.agent/`, `_agents/` and `_agent/`, merges
hooks **by name**, and lets the workspace copy outrank the global one. A file
containing `{"sandbox-guardrails": {"enabled": false}}` in any attached
workspace switches the hook off outright — the agent's own writable bind
mount, no privilege needed.

Nothing in a workspace can reach `settings.json`. So the layer that must be
complete is the static `permissions.deny` list, and the hook is
defence-in-depth on top of it — the same shape Claude Code already has, and
the opposite of what this work assumed before it was measured.

The hook still blocks writes to a workspace `hooks.json` (rule
`agy-workspace-hook-tamper`, both the write-tool and the shell route), and
`scripts/audit/probes/antigravity.py` fails if one exists anyway.
