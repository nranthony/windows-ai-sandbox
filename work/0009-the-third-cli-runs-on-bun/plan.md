# 0009 — plan: adding opencode as the third in-container CLI

Design and ordered steps. Read [`spec.md`](spec.md) first — the findings F1–F7 and
decisions D1–D6 are what these steps implement, and several steps exist only because
of a specific finding. Its §0 subsection "What Bun is" is the prerequisite for all of
them.

**This item is parked** (spec status). The phases below are what to do on unparking, in
order — not a queue anyone is currently working.

**Phase 0 is not optional.** Five of the seven findings end in "measure this before
writing it". Skipping T01 means writing security-critical config against guesses about
a runtime this repo has never run — and, because the item is parked, against guesses
that were already stale when they were made.

---

## Phase 0 — measure, before a single file changes

### T01 — one throwaway container, seven questions plus one contingency

Build a scratch image with `npm i -g --allow-scripts=opencode-ai opencode-ai` on top
of the current one and run it under the **real** runtime hardening (seccomp +
`cap_drop ALL` + `no-new-privileges` + the internal network) — `scripts/run-ephemeral.sh`
is the existing route for exactly this. Record answers in `notes.md`:

| # | Question | Why it gates a step | Settles |
|---|---|---|---|
| Q1 | Does `opencode --version` work with `--allow-scripts=opencode-ai`, and does it *fail* without it? | F4 — differential, both directions. "It worked" is not evidence the flag was needed | T02 |
| Q2 | Does the binary start at all under the seccomp allowlist, and does a **real session** (socket, file watch, local TUI server) also survive it? | F6, DoD 5. `io_uring_*` is absent from `seccomp.json` and `userfaultfd` is explicitly removed (`:133`); the JIT's mapping syscalls ARE present (`:48-50`), so the risk is Bun's Zig I/O layer, not JSC. A new syscall need is a `seccomp.json` edit — separate security review, own ADR | T13 |
| Q2b | If Q2 fails: does the same image work with seccomp swapped for `unconfined`? | F6 — `ptrace` is absent from the allowlist (`:119`) so `strace` is unavailable in-container; the unconfined comparison run is the substitute, and it turns open-ended debugging into a bisect. **Scratch container only, never a profile** | T13 |
| Q3 | With `HTTPS_PROXY` set, does the models.dev startup fetch appear in `docker exec egress-proxy-<p> …` access.log? | F3 — decides whether `models.dev` gets an allowlist line or would be a decorative one | T07 |
| Q4 | Does the **provider SDK install** traverse Squid? Trigger it with `--with npm` open and watch access.log | F1/F3 — decides whether the one-time first-run flow is `with-egress` or impossible | T09 |
| Q5 | Does a global `/root/.bunfig.toml` with `[install] minimumReleaseAge` actually constrain that install? Test with a package published inside the window | D5/F1. If it does not bind, the honest outcome is a documented gap, not a file that looks like a gate | T03 |
| Q6 | Where exactly do config, cache and auth land? Confirm `~/.config/opencode/opencode.json`, `~/.cache/opencode/packages`, `~/.local/share/opencode/auth.json` | F2 and the "no new mount" claim in spec §2 | T06 |
| Q7 | Does `{env:OPENROUTER_API_KEY}` in `opencode.json` authenticate without `/connect`? And does opencode keep TUI prefs in a separate `tui.json`? | D1 and D2's carve-out | T06, T08 |

**Fail-closed reading.** Q3/Q4 answering "no, it bypasses the proxy" is not a blocker —
per F3 it means the call fails closed on this network. It is a blocker for *writing an
allowlist entry*, which is the point of asking.

---

## Phase 1 — image

### T02 — install opencode in the AI CLI refresh layer

`Dockerfile`, the `AI_CLI_REFRESH` block. Extend the existing RUN — do not add a new
layer, the whole point of that block is that all AI CLIs rebuild together as one tail:

```dockerfile
ARG OPENCODE_VERSION=latest
RUN npm install -g --allow-scripts=@anthropic-ai/claude-code "@anthropic-ai/claude-code@${CLAUDE_VERSION}" \
 && npm install -g --allow-scripts=opencode-ai "opencode-ai@${OPENCODE_VERSION}" \
 && curl -fsSL https://antigravity.google/cli/install.sh | bash -s -- --dir /usr/local/bin \
 && claude --version \
 && opencode --version \
 && /usr/local/bin/agy --version
```

`--allow-scripts=opencode-ai` per F4/Q1; `opencode --version` in the same RUN so a
blocked postinstall fails the **build** rather than surfacing months later as a broken
CLI. Update the block comment to name three CLIs, and state that opencode's runtime is
Bun with its own package installer (F1) — that sentence is the pointer a future reader
needs before they touch Gate 2. Frame it as **three CLIs, two runtimes**: that is the
distinction the block's ordering rules actually turn on, and "three CLIs" alone hides it.

### T03 — Bun's half of Gate 2 (conditional on Q5)

If Q5 says a global bunfig binds: write `/root/.bunfig.toml` in the Dockerfile,
**below** the CLI install and beside the Gate 2 npm block:

```toml
[install]
minimumReleaseAge = 604800  # 7 days, in SECONDS
```

Three package managers, three units — npm days, pnpm minutes, bun seconds. Say so in
the comment; the pnpm block already carries the equivalent warning and it exists
because the mistake was made.

`/root/.bunfig.toml` sits in the image layer and is **not** masked at runtime: only
`/root/.claude`, `/root/.claude.json`, `/root/.cache`, `/root/.config`, `/root/.gemini`,
`/root/.kaggle`, `/root/.npm-global` and `/root/.local` are mounted over. Verify that
claim rather than trusting this sentence.

If Q5 says it does **not** bind: write the gap into the Gate 2 block as prose — "bun,
used by opencode's runtime provider installer, is NOT covered; the fetched package
lands in the persistent `/root/.cache` bind mount" — and raise it as its own item.
Leaving it unstated is precisely the failure work/0008 documents.

### T04 — extend `scripts/dockerfile-order.test.sh` (8/8 → 9+/N)

New assertion: the opencode `npm install -g` appears **above** the Gate 2 npmrc write.
Same reason as claude's, restated so it survives being read in isolation —
`min-release-age` applies at build time, so a Gate-2-above-install ordering makes
`opencode-ai@latest` unresolvable whenever upstream published inside the window, and
the break is *intermittent* (it depends on when upstream last shipped) and surfaces on
a routine `--refresh-ai`, not on a cold build.

### T05 — build flags

`scripts/profile.sh`, both flag parsers (`~:750` and `~:944` — there are two, and they
must stay in step):

- `--refresh-ai` — no signature change; it already busts `AI_CLI_REFRESH`, which now
  covers three CLIs. Update its help text (`~:85`) to say three.
- `--opencode-version=X.Y.Z` — `--build-arg OPENCODE_VERSION=…` plus a fresh
  `AI_CLI_REFRESH`, mirroring `--claude-version=` exactly.
- Update the `fail` message at `~:953` listing valid flags, and the `justfile` build
  comment at `:63`.

---

## Phase 2 — profile state and configuration

### T06 — the config template

New: `sandbox_templates/opencode/opencode.json`. Container path
`/root/.config/opencode/opencode.json`; host path
`~/.ai-sandbox/profiles/<p>/config/opencode/opencode.json` via the **existing**
`/root/.config` mount. **No `docker-compose.yml` change.**

Skeleton (D1/D3/D4; JSON has no comments, so annotate with `_`-prefixed keys the way
`claude-settings.json` does — and note the audit probe must strip them, as
`settings.py::_strip_doc_keys` already does for Claude):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "autoupdate": false,
  "share": "disabled",
  "provider": {
    "openrouter": {
      "options": { "apiKey": "{env:OPENROUTER_API_KEY}" }
    }
  },
  "permission": {
    "*": "ask",
    "read": "allow",
    "grep": "allow",
    "glob": "allow",
    "webfetch": "deny",
    "websearch": "deny",
    "external_directory": "deny",
    "bash": {
      "*": "ask",
      "git status": "allow", "git diff*": "allow", "git log*": "allow",
      "npm install*": "deny", "npm ci*": "deny", "npx*": "deny",
      "pip install*": "deny", "uv pip install*": "deny", "uv add*": "deny",
      "curl*": "deny", "wget*": "deny",
      "git push*": "deny", "git clone*": "deny",
      "rm -rf*": "deny", "sudo*": "deny", "docker*": "deny"
    }
  }
}
```

Four things this skeleton is **not** yet, all of which are the actual work of T06:

1. **Order-checked.** Last match wins (F5). Every rule must be read in file order and
   the resulting policy written out, not assumed. `{"*": "ask"}` first, specifics
   after.
2. **Coverage-checked against `settings.py::REQUIRED_DENY`.** Walk all seven Claude
   deny categories — network, vcs, installers, shell_escape, destructive, system,
   read_patterns — and for each decide the opencode expression or record why the
   category does not apply. The installers category grew on 2026-08-18 (`npm exec`,
   `pnpm exec`, `yarn dlx`, `bunx`, `bun x`, `pip download`); take the **current** list,
   not the one in this file.
3. **`read` scoped.** `"read": "allow"` above is too broad — opencode denies `.env` by
   default but Claude's `read_patterns` also covers `*.pem`, `*.key`, `id_rsa*`,
   `.credentials*`, `/root/.gemini/**`, `/root/.config/gh/**`, `/root/.claude.json`.
   Express those as an object with denies after the allow.
4. **Annotated with the F5 hazard and the §5 gap.** Two sentences minimum: that
   unlisted keys default to `allow` here (unlike Claude's classifier), and that no
   `deny-destructive.sh` equivalent guards opencode — so the manifest-edit route
   (adding a dep name to `pyproject.toml`, then resolving it with an allowed build
   command) is **not** blocked for this CLI. Write it where it will be read.

### T07 — egress delta

`proxy/allowed_domains.txt`:

- `[openrouter]`, ALWAYS ON — the block already exists and `openrouter.ai` is already
  live. Replace the `# claude, fill in here` placeholder with real prose: what uses it
  (opencode via the OpenRouter provider), that it is pinned with no
  `.openrouter.ai` wildcard per M3, and that OpenRouter is behind Cloudflare so
  IP-based rules are not an option.
- `models.dev` — **only if Q3 says the fetch traverses Squid.** If it does not, add
  nothing and record why in the `[opencode-install]` comment; a line that cannot take
  effect is worse than no line, because its presence asserts a control.
- `[opencode-install]`, PLANNING-MODE, commented — `opencode.ai`. Must use the
  `# # ---NAME [TAG] ---` double-comment header form or `with-egress.sh` cannot find
  it; copy the `[antigravity-install]` block's shape verbatim. State the same argument
  its neighbour makes: the install happens at **build** time on the host network,
  bypassing Squid, so this block is only for the rare in-container install.
- Do **not** open `registry.npmjs.org`. First-run provider fetch goes through T09.

Note the domain-line format trap now enforced by the in-flight `with-egress.sh`
change: a line carrying a domain **plus** trailing prose is deliberately left alone by
`open_section`. Any host meant to be openable must be on its own line.

Then, three files that fail *silently* if they disagree:

- `scripts/audit/probes/proxy.py` — add `opencode-install` to `GATED_TAGS`.
- `dashboard/src/lib/proxy_categories.py` — add both tags to `"AI / LLM CLIs & APIs"`.
- `scripts/audit/probes/proxy.py::REQUIRED_DOMAINS` — add `openrouter.ai` if the
  always-on posture should be asserted rather than merely present.

### T08 — the key

`sandbox_templates/common/secrets.env.template`: add `OPENROUTER_API_KEY`. That file
demands each name be **cited to its consumer** ("VARIABLE NAMES ARE NOT A MATTER OF
TASTE… a plausible-looking synonym fails silently as a missing key") — so cite the
`{env:OPENROUTER_API_KEY}` reference in `sandbox_templates/opencode/opencode.json`,
not a vendor doc. Include the operational trap the file already documents for every
other key: **`env_file` is read at container CREATE only**, so a profile that adds the
key must `recreate`, not `up`.

### T09 — first-run provider install, documented as a one-time gated step

Per F1 the provider SDK is fetched from npm on first use. `[npm]` is gated off by
ADR-0003, and `with-egress.sh` is the only sanctioned route in:

```bash
scripts/with-egress.sh <profile> --with npm -- 'opencode run --model openrouter/... "hello"'
```

It lands in `~/.cache/opencode/packages` → the profile's persistent `cache/` dir, so
this is **once per profile**, not once per container, and it produces an audit-log
line the way every other dependency entering a profile does.

Do **not** try to pre-warm this at build time: `/root/.cache` is a per-profile bind
mount, so anything baked into that path in the image is **masked at runtime and
invisible**. Write that sentence into the doc — it is the obvious optimisation and it
silently does nothing.

### T10 — seeding

`scripts/profile.sh::ensure_state` and its mirror `scripts/init-profile-state.sh` (they
must stay in step; the file says so and the pnpm/git-identity blocks already carry that
note):

- `mkdir -p "$p/config/opencode"`.
- Deploy `sandbox_templates/opencode/opencode.json` per **D2**. If converge: overwrite
  on every `up`, no `.bak` files — ADR-0005's rule is that a stamped backup beside a
  live config is a second live copy, and `verify` asserts no `*.bak*` sits beside
  seeded content.
- `reset-opencode` subcommand mirroring `reset-settings` (`profile.sh:~1348`), for the
  case where you want the reset without touching the container.

---

## Phase 3 — detectors

The repo's stated rule: *a control with no detector drifts, and a skip is not a pass.*

### T11 — `scripts/verify-sandbox.sh` (tier 1)

- `command -v opencode` — mirroring the `claude CLI present` check at `:155`.
- `opencode --version` returns a real version. This is the F4 regression lock: a
  present-but-broken binary is the documented failure mode, and presence alone does not
  catch it.
- Live `opencode.json` exists, parses, and (if D2 = converge) matches the template.

### T12 — `scripts/audit/probes/opencode.py` (tier 2)

New module per D6. Assertions:

- live config present + parses;
- `autoupdate` false, `share` disabled;
- the provider key is a `{env:…}` reference — **fail if a literal key is inline**, which
  is the accident D1 exists to prevent;
- `permission` present with a restrictive `"*"`; the required deny expressions present;
- last-match ordering is intact, i.e. no later rule silently re-permits something an
  earlier deny covered (this is the check that actually earns the module — a set-membership
  test cannot see it);
- live-vs-template diff, `_`-prefixed keys stripped as `settings.py::_strip_doc_keys`
  already does.

Then update the probe count: **65 appears in `README.md` at `:100`, `:200` and `:320`**,
and `.agents/skills/security-audit.md:9` still says "~80" and is already wrong — fix it
in the same pass rather than adding a third number to the pile.

### T13 — live run under hardening

Confirm Q2's answer holds for a real session, not just `--version`: seccomp +
`cap_drop ALL` + `no-new-privileges`, a real OpenRouter round trip, an `ask` prompt
observed, and a `deny` rule observed blocking. Prove denies **differentially** (same
command, rule present vs absent) — that is the standard `claude-settings.json`'s
`_ask_note` set for this repo, and it is the only evidence that survives an upstream
version bump.

---

## Phase 4 — docs

| File | Change |
|---|---|
| `AGENTS.md` | `sandbox_templates/opencode/` on the security-sensitive list; the new test requirement from T04 |
| `ARCHITECTURE.md` | three CLIs, not two — **and two JavaScript runtimes, not one**, which is the fact the dependency-gate and syscall sections are silently written against; state layout row for `config/opencode/` |
| `README.md` | three CLIs; new build flag; probe count (three places) |
| `docs/permissions-model.md` | the F5 comparison — two permission languages, why the postures differ in expression and match in intent, and the §5 gap (no hook equivalent) |
| `docs/index.md` | index whatever new doc T06/T09 produce |
| `.agents/skills/profile-lifecycle.md` | first-run provider install (T09); `reset-opencode` |
| `.agents/skills/squid-management.md` | `[opencode-install]` tag; the F3 caveat that a Bun-runtime call may not traverse Squid at all, so a TCP_DENIED is not the only way this CLI fails to reach a host |
| `docs/adr/` | **ADR only if** Q2/T13 forces a `seccomp.json` change (F6) or D5 lands as an accepted uncovered Gate 2 gap (F1). Adding a third CLI is not itself an ADR-tier decision; weakening the syscall filter or accepting a dependency-gate hole is |

---

## Landing order note

**This is a moving target, and the item is parked — re-check it on unparking rather
than trusting the snapshot below.**

As of 2026-08-20 the earlier conflict is **gone**: the `[git]` accepted-open decision,
the installer-deny expansion and the `open_section` prose-leak fix have all landed, so
`proxy/allowed_domains.txt`, `scripts/with-egress.sh` and
`scripts/audit/probes/{proxy,settings}.py` — the T07/T12 targets — are clean. That was
the overlap worth waiting on, because it was in security-critical files.

What is in flight *now* is a different and much weaker overlap: `AGENTS.md`,
`README.md` and `docs/index.md` are modified by the agent-notice work
(`scripts/agent-notice.test.sh`, new — `just test-offline` is seven suites now, not
six), alongside a myconv skills re-vendor. Those three are **Phase 4 docs targets
only**. Phase 4 is the last phase and touches no guarantee, so this does not gate
starting.

The durable rule, which is what actually matters here: **do not start Phase 1–3 while a
T07 or T12 target is uncommitted.** Being the first person to run a Bun binary in this
sandbox and resolving conflicts in security-critical files are two kinds of uncertainty
that should not share a diff. Doc-only overlap does not meet that bar.
