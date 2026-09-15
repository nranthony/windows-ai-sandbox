# 0029 — plan

Ordered by leverage, then by blast radius. Phases A–C change the threat model;
D–F are incremental. Each phase ends green on `just test-offline` and a
tier-1 `verify` in one profile.

## Phase A — no-code, do first (host side)

- [ ] A1 Re-issue GitHub credentials per profile as fine-grained PATs
      (spec D3): that profile's repos, `contents:write` +
      `pull_requests:write`, no `gist`, 90-day expiry. Log in with
      `gh auth login --with-token`. Record the scopes in
      `sandbox_templates/common/secrets.env.template` as a comment.
- [ ] A2 Branch-protect `main` on every repo an agent profile can push to.
- [ ] A3 Rotate the reader-service keys (Tavily, Firecrawl, TinyFish, Jina)
      after Phase C, since they have been agent-readable since issue.

## Phase B — policy pins (template edits, converge to pick up)

- [ ] B1 `permissions.deny` += `WebFetch` (spec F5). Update `_webfetch_note`
      to say *why deny rather than unlisted*, and fold 0025's "WebFetch scoping
      unrealised" row into this. Per-repo `WebFetch(domain:...)` allows stop
      working — that is intended; the broker is the read path.
- [ ] B2 Top-level `"disableBypassPermissionsMode": "disable"` and
      `"enableAllProjectMcpServers": false` (spec F6). Add both to the
      sandbox-owned key list `profile.sh` converges and `verify` compares.
- [ ] B3 **Measure** how a cloned repo's `.claude/settings.json` hooks and
      `.mcp.json` are treated at trust time: a fixture repo under `tests/` with
      a hook that touches a sentinel file. Record the result in `notes.md`;
      if the hook runs, add a hook-engine rule that blocks Edit/Write to
      `**/.claude/settings*.json` inside `/workspace` and an `agent-policy`
      test that pins it.
- [ ] B4 Hook-engine rule (spec F3 interim): block Bash whose command text
      references `/root/.claude/.credentials.json`, `/root/.config/gh/`,
      `/root/.gemini/`, `/root/.claude.json`, `/proc/*/environ`, or
      `secrets.env`. Regex on the envelope, same as the existing tamper
      rules. This is a speed bump until Phase C, and stays afterwards.

## Phase C — credential relay (spec §3)

- [ ] C1 New service `cred-relay-<profile>` in `docker-compose.yml`:
      `sandbox-internal` only, `read_only`, `cap_drop: ALL`, default seccomp,
      reads `~/.ai-sandbox/profiles/<p>/relay.env` (0600, operator-owned,
      NOT mounted into the agent). Plain HTTP inside the internal network;
      upstream via Squid with the real credential added as a header.
- [ ] C2 Anthropic half: `profile.sh <p> backend relay` writes
      `ANTHROPIC_BASE_URL=http://cred-relay:8080` into `backend.env`; the
      relay forwards to `api.anthropic.com` with the OAuth/API credential.
      Remove `.credentials.json` from the agent's `claude-home` mount for that
      profile and measure that Claude Code still starts and completes a turn.
- [ ] C3 GitHub half (spec D2): relay route `http://cred-relay:8081/<owner>/<repo>.git`
      → `https://github.com/...` with the PAT injected. `setup.sh` rewrites
      the workspace's `origin` to the relay URL; `gh` is already denied, so
      `hosts.yml` is deleted from the profile's `config/` mount.
- [ ] C4 Move the `webfetch` broker into the relay (spec D1b): the agent-side
      `webfetch` becomes a thin client to `http://cred-relay:8082`; the relay
      holds the backend keys and refuses any target URL whose host is not in
      a new `proxy/webfetch_targets.txt`. Port `scripts/webfetch.test.sh`
      (90 cases) to the new split; add cases for the refused host and for
      a key never appearing in the agent's environment.
- [ ] C5 Drop the reader-service hosts, `openrouter.ai`, `api.openai.com`,
      `api.smith.langchain.com`, `generativelanguage.googleapis.com` and the
      fal block from `proxy/allowed_domains.txt` (spec F1, F2). The relay
      reaches them via its own Squid ACL (`src` = relay's static IP) — a
      second `dstdomain` list the agent's IP is not allowed to use.
- [ ] C6 `verify` tier-1: assert no file under the agent's mounts matches
      `.credentials*`, `hosts.yml`, `oauth_creds.json`; assert the agent
      container's env has no `*_API_KEY`/`*_TOKEN` except `NO_PROXY`/proxy
      vars; assert the relay is on `sandbox-internal` only.

## Phase D — Squid and audit

- [ ] D1 `proxy/squid.conf`: deny `Safe_ports` 80 entirely (443 only);
      `request_body_max_size 4 MB` (spec F8). Measure a `git push` of a
      normal commit through the relay still succeeds; large-file pushes are
      a human step and that is acceptable.
- [ ] D2 Bind-mount `/var/log/squid` to `~/.ai-sandbox/profiles/<p>/audit/squid/`
      (spec F7), rotated by Squid's own `logfile_rotate`. `verify` fails
      if the log is on tmpfs.
- [ ] D3 A `profile.sh <p> egress-report` verb: bytes per destination host
      over the last N hours from the persisted log, so a 50 MB day to one
      host is visible.

## Phase E — surface

- [ ] E1 GPU overlay opt-in (spec D5): `profile.sh <p> gpu enable|disable`
      writes a marker; detection of `/dev/dxg` becomes a *prerequisite*, not
      a trigger. `SANDBOX_GPU=1` stays as the override.

## Phase F — non-root agent (spec D4, largest diff, ships last)

- [ ] F1 `Dockerfile`: `useradd agent` (UID 1000), hook script and
      `/usr/local/lib/claude-hooks/` root-owned 0755, `USER agent` at the end.
      Copy macolima's Dockerfile pattern (`:323`, `:376`, `:518`).
- [ ] F2 Every `/root/...` mount target in `docker-compose.yml:51-81` and
      every template path under `sandbox_templates/` → `/home/agent/...`.
      `profile.sh ensure_state` chowns persisted profile dirs to host UID 1000
      (already the case under rootless; verify the mapping is identity for the
      new user).
- [ ] F3 Drop the "agent runs as root here" caveat from `_hooks_comment` and
      from `docs/deny-destructive-hook-plan.md`; `verify` asserts the hook
      script is not writable by the agent.

## Exit

All phases merged, `SECURITY_ASSESSMENT.md` §4 rec. 1 marked closed with a
pointer here, sibling replay report ferried to `macolima@work/0012`, folder
archived to `docs/_archive/`.
