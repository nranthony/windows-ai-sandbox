# 0009 — the third CLI runs on Bun

**Status:** **Parked — specified, not scheduled.** Raised 2026-08-18 by owner request:
add **opencode** as a third in-container agentic CLI alongside Claude Code and
Antigravity (`agy`), driven by **OpenRouter** as the model provider, mirroring the
settings and permission posture the other two already carry.

Written up now so the shape of the job is known and the findings are not re-derived
later. **Implementation waits until opencode is actually wanted in a profile.** Nothing
here is blocked; it is on hold.

**Shelf life — read before implementing from this document.** The *structural* findings
(F1, F2, F5, F6 — a different package manager, different config paths, a different
permission language, a new runtime under a default-deny syscall filter) hold for as long
as opencode is a Bun binary. The *version-dependent* ones do not: F3's proxy behaviour
and F4's postinstall shape were read against `opencode-ai@1.18.18` on 2026-08-18, and
F3 is explicitly a behaviour that has changed across releases. Re-read the registry
entry and re-run Phase 0 on unparking. Do not implement from this file without
measuring first — that is the same instruction Phase 0 already carries, restated here
because a parked item is read cold.

**Exit rule:** delete this folder, or move to [`docs/_archive/`](../../docs/_archive/),
when the work merges.

**Security-sensitive.** The change touches `Dockerfile`, `proxy/allowed_domains.txt`,
`scripts/profile.sh`, `scripts/verify-sandbox.sh`, and adds a new agent whose tool
permissions are enforced by a system this repo has never audited. Every commit needs
a SECURITY IMPACT line, `scripts/profile.sh <p> verify` (tier 1) green, and
`scripts/profile.sh <p> audit` (tier 2) run — see [AGENTS.md](../../AGENTS.md),
"Security-sensitive changes". `just test-offline` before calling it done.

---

## 0. How to re-enter this cold

The one-line thesis, and the reason this is a work item rather than three lines in
the Dockerfile:

> **Claude Code and `agy` are Node/native binaries. opencode is a Bun binary that
> installs its own npm packages at runtime. Every control this repo built around
> npm, pnpm and Node's proxy handling — Gate 2's quarantine, the `HTTP_PROXY`
> environment, the `/root/.local` tmpfs assumption — either does not apply to it or
> applies through a different file. "Mirror the Claude settings" is therefore not a
> transcription job; it is a re-derivation against a different runtime.**

Everything in §3 follows from that. §4 is the decision set; nothing in §5 should be
attempted in the first pass. If "Bun" is a name and not yet a mental model, read the
next subsection first — the findings are unreadable without it.

### What Bun is, and why it is the whole work item

Bun is a JavaScript runtime — a direct alternative to Node.js. Different engine
(JavaScriptCore, Safari's, rather than V8), written in Zig, and unlike Node it bundles
the package manager, bundler and test runner into the same binary. Its other property
is the one that matters here: `bun build --compile` welds the runtime and the
application into a **single standalone per-platform executable**. opencode ships that
way, and that single fact generates F1, F4 and F6.

Two consequences run through every finding below:

1. **A different package manager reads different files.** Bun does not consult
   `/usr/etc/npmrc` or `~/.config/pnpm/rc`. It reads `bunfig.toml`. Every Gate 2
   control this repo has written is invisible to it (F1).
2. **opencode is not finished at build time.** Claude Code and `agy` are complete
   artifacts once the image is built — whatever they need, they have before the
   container starts. opencode arrives as a package manager and then *goes shopping at
   runtime*: it fetches provider SDKs on first use, into a persistent bind mount, inside
   a running profile (F1, T09).

So adding opencode is not "a third CLI onto a shelf that already holds two". It is
introducing a **second JavaScript runtime, with its own package manager**, into an image
whose dependency gates, proxy assumptions and syscall filter were every one of them
written against the first.

**There is no existing Bun surface here.** Verified 2026-08-20: the string `bun` appears
nowhere in this repo outside this work item — every apparent hit is "Ubuntu". No
`bunfig.toml`, nothing in the `Dockerfile`, nothing in `seccomp.json` written with it in
mind. That is *why* F1 and F6 exist. It also means there is nothing to retrofit or
reconcile, only something to add — which is the one piece of good news in this section.

---

## 1. Scope

**In.** opencode installed into the shared image at the same layer as the other two
CLIs and refreshed by the same build flag; a seeded, converged per-profile
`opencode.json` carrying a permission posture equivalent in intent to
`claude-settings.json`; OpenRouter wired as the provider with the key arriving the
way every other key in this sandbox arrives (`secrets.env`, never argv); the egress
delta, sized down to what actually has to traverse Squid; detectors so the new
controls cannot drift silently.

**Out (first pass).** MCP servers under opencode's `mcp` key; opencode plugins as a
`deny-destructive.sh` equivalent; opencode custom agents/commands/skills; the
dashboard growing an opencode panel; any second provider besides OpenRouter.

---

## 2. What "mirrors Claude Code and antigravity" resolves to

Three CLIs, three integration surfaces. The table is the spec:

| Surface | Claude Code | `agy` | opencode (proposed) |
|---|---|---|---|
| Install | `npm i -g @anthropic-ai/claude-code` in the AI refresh layer | `install.sh --dir /usr/local/bin`, same layer | `npm i -g opencode-ai`, **same layer** (T02) |
| Version bump | `--refresh-ai`, `--claude-version=` | `--refresh-ai` | `--refresh-ai`, `--opencode-version=` (T05) |
| Auth | `/root/.claude/.credentials.json` (bind mount, persists) | console sign-in, **not** persisted | env key from `secrets.env` (D1) |
| Config home | `/root/.claude` → profile `claude-home/` | `/root/.gemini` → profile `gemini-home/` | `/root/.config/opencode/` → profile `config/` — **already mounted, no new volume** |
| Permissions | `permissions.{allow,ask,deny}`, prefix matcher | none of ours | `permission.{read,edit,bash,…}`, last-match-wins globs (D3) |
| Autoupdate off | `DISABLE_AUTOUPDATER=1` env + settings | n/a (image-baked) | `OPENCODE_DISABLE_AUTOUPDATE` env + `"autoupdate": false` |
| Egress | `[claude]` always-on | `[antigravity]` always-on, `[antigravity-install]` gated | `[openrouter]` always-on (exists), `[opencode-install]` gated (T07) |
| Detector | `settings.py` probe, `verify` checks | `[antigravity]` in probe `REQUIRED_DOMAINS` | new probe section (T12) |

The config-home row is the one piece of luck in this work item: opencode's global
config lives at `~/.config/opencode/opencode.json`, and `/root/.config` is **already**
a per-profile bind mount (`docker-compose.yml:67`). The config persists across
recreates with **zero changes to compose**. Do not add a mount for it.

---

## 3. Findings that shape the design

Each is evidence, not inference. Where a claim is unmeasured it says so, and the
plan's first phase measures it before anything is written.

### F1 — Gate 2 does not cover opencode's package installs

opencode does not ship its provider SDKs. It installs them **at runtime, with Bun**,
into `~/.cache/opencode/packages` — first use of a provider triggers the fetch.
Upstream's own enterprise page confirms the shape by documenting private-registry
auth via `.npmrc`; upstream issue #4150 is a user hitting exactly this.

The sandbox's slopsquat quarantine is configured in two places and **neither is one
Bun reads**:

| Gate 2 layer | File | Unit | Read by Bun? |
|---|---|---|---|
| npm | `/usr/etc/npmrc` (`min-release-age=7`), Dockerfile | days | **no** — npm `globalconfig`, not a path Bun consults |
| pnpm | `~/.config/pnpm/rc` (`minimum-release-age=10080`), `ensure_state` | minutes | no |
| **bun** | **`~/.bunfig.toml` `[install] minimumReleaseAge`** | **seconds** | yes — and it does not exist here |

So the first `opencode` run with a fresh provider resolves a package from
`registry.npmjs.org` with **no quarantine window at all**, and it lands in
`/root/.cache` — a *persistent, exec-allowed* bind mount, not the disposable
writable layer. That is a straightforwardly worse resting place than anything Gate 2
currently guards.

Counted across the whole image: **Gate 2 covers two package managers (npm, pnpm), Gate 3
covers two more (uv, pip). Bun is a fifth — and the first with no gate on it at all.**

Bun does implement the control (`bunfig.toml`, `[install] minimumReleaseAge`, in
**seconds** — a third unit for the third package manager). Whether opencode's
embedded installer honours a *global* `~/.bunfig.toml` when it spawns is **not
measured** and is T01. Note the documented Bun limitation: `minimumReleaseAge` is
checked at resolution only, so a version already pinned in a `bun.lock` is installed
without the cooldown.

### F2 — the OpenRouter key would land on an ephemeral noexec tmpfs

opencode's `/connect` flow writes credentials to
`~/.local/share/opencode/auth.json`. In this image `/root/.local` is
`tmpfs:size=256m,noexec,nosuid,nodev` (`docker-compose.yml:54`). The key would
therefore be **destroyed on every recreate** — the `agy` re-auth-per-rebuild
annoyance, but for a credential the profile owner pasted rather than an OAuth flow
they can replay in ten seconds.

This is a reason to prefer the env route (D1), not a reason to add a mount.

### F3 — an allowlist entry only helps if the call goes through Squid

opencode's runtime is Bun, and Bun's `fetch()` has not always honoured
`HTTP_PROXY`/`HTTPS_PROXY`. Upstream issue #4959 reports the models.dev startup
fetch going direct and ignoring the proxy environment; opencode's own network page
now documents the proxy variables as supported, so the behaviour is
**version-dependent and must be measured, not assumed** (T01).

Note the trap in reasoning from the other two CLIs: **honouring `HTTP_PROXY` is a
property of the HTTP client library, not of the platform or the runtime.** Node's own
built-in `fetch` does not honour it either; Claude Code and `agy` traverse Squid because
the libraries *they* use do. "The other two CLIs work through the proxy" is therefore no
evidence whatsoever about a third one. Each new client is its own measurement, and this
is the general rule that Q3 and Q4 are one instance of.

The consequence is specific to this sandbox and cuts both ways:

- `sandbox-internal` is `internal: true` and DNS is sinkholed to `127.0.0.1`. A call
  that bypasses the proxy does not leak — **it fails closed**, with no route and no
  resolver. Good.
- But then adding `models.dev` to `allowed_domains.txt` buys **nothing**, because the
  traffic never reaches Squid to be allowed. The pasted research recommends
  allowlisting it as "the less surprising choice"; here that would be a line in a
  security-critical file that does not do what its presence implies.

So: measure which of opencode's call paths traverse Squid, and write allowlist
entries **only** for those. The rest fail closed and fall back (models.dev has a
`~/.cache/opencode/models.json` cache and a bundled snapshot).

The one path already proven correct is the compose environment: `NO_PROXY` already
contains `localhost,127.0.0.1` (`docker-compose.yml:96`), which is exactly the
routing-loop bypass opencode's network docs require for its local TUI server. **No
change needed** — that item from the research is already satisfied.

### F4 — opencode-ai has a postinstall, and this image blocks postinstalls

`opencode-ai@1.18.18` (npm registry, read 2026-08-18) carries **both**
platform-specific `optionalDependencies` (linux x64/arm64, musl and baseline
variants) **and** `"postinstall": "node ./postinstall.mjs"`, with `bin` pointing at
`bin/opencode.exe`.

That shape is not incidental — it follows directly from how Bun ships (§0). A
`bun build --compile` artifact is a per-platform executable, so the npm package cannot
*be* the program; it can only be a thin installer that resolves the right
`linux-x64`/`arm64`/musl/baseline binary out of `optionalDependencies` and puts it where
`bin` points. **The install is a script by construction**, which is exactly the class of
thing this image blocks by default. Any future Bun-compiled CLI will arrive with the
same shape, so this is a reusable expectation rather than a quirk of one package.

npm 12 in this image blocks lifecycle scripts by default (`allow-scripts = [""]`),
which is why the Claude install carries
`--allow-scripts=@anthropic-ai/claude-code`. The failure mode when it is missing is
already documented in this repo and in the owner's notes: the CLI installs, exits 0,
and then reports a broken native binary at run time. Expect
`--allow-scripts=opencode-ai` to be required, and **prove it** by running
`opencode --version` in the build (T02), exactly as the claude/agy line does.

### F5 — the permission model is a different shape; transcribing the deny list is wrong

`claude-settings.json` denies on a **command prefix**, and its `_comment` is explicit
that wrappers route around it. opencode resolves permissions with **last-matching-rule
wins** over glob patterns, across a different key set: `read`, `edit`, `bash`, `glob`,
`grep`, `task`, `skill`, `lsp`, `question`, `webfetch`, `websearch`,
`external_directory`, `doom_loop`, plus a `"*"` global default. Most default to
`allow`; `doom_loop` and `external_directory` default to `ask`.

Two consequences:

1. **Rule order is load-bearing and inverted from intuition.** `{"*": "deny", "git *":
   "allow"}` and `{"git *": "allow", "*": "deny"}` are different policies. Claude's
   list is order-free; a mechanical port would silently produce the wrong one.
2. **`allow` is the default for most keys**, where Claude's `defaultMode: auto` hands
   unlisted commands to a classifier. The repo already learned — and wrote into
   `claude-settings.json`'s `_ask_note`, with a differential test — that *absence
   alone does not produce a prompt*. Under opencode, absence produces **allow**. So
   the equivalent-intent posture needs an explicit restrictive `"*"` and cannot rely
   on omission at all.

`webfetch`/`websearch` deserve their own decision: this sandbox deliberately routes
arbitrary reads through the `webfetch` broker (`docs/web-read-broker.md`) so that
page domains never enter the allowlist. An opencode `webfetch` set to `allow` would
be a second, unbrokered path — and one whose fetches, per F3, may not even traverse
Squid.

### F6 — Bun is a new runtime under a default-deny syscall filter, and has never run here

`seccomp.json` is `defaultAction: SCMP_ACT_ERRNO` (`:14`) — an allowlist, not a
blocklist. It was written against the syscall needs of the software already in this
image, and per §0 no Bun binary has ever been among that software. Two specifics, read
from the file on 2026-08-20:

- **`userfaultfd` is deliberately absent**, reason recorded in-file as "can be used in
  kernel exploits" (`seccomp.json:133`).
- **No `io_uring_*` syscall appears in the allowlist at all**, so default-deny covers
  the whole family.

What is *not* a concern: JavaScriptCore's JIT needs W^X page mappings, and `mmap`,
`mprotect`, `mremap`, `madvise`, `membarrier` and `memfd_create` are all present
(`seccomp.json:48-50`). The JIT should be satisfied. **The unknown is Bun's own I/O
layer** — written in Zig rather than inherited from libuv, so it makes its own syscall
choices, and those are the ones nothing here has exercised.

Two notes on how this will actually be diagnosed, because they change how long it takes:

1. **`--version` is not the test.** A denied syscall may sit on a path that only a real
   session reaches — sockets, file watching, the local TUI server. That is why Q2 and
   T13 are separate steps rather than one.
2. **You cannot `strace` it.** `ptrace` is deliberately absent from the allowlist too
   (`seccomp.json:119`, "process debugging — can inspect/modify other processes"). A
   denied syscall under `SCMP_ACT_ERRNO` returns an ordinary errno, so the failure will
   read as a bug in opencode rather than as sandbox policy, and the usual tool for
   telling those apart is not available inside the container. Diagnose by comparison
   instead: run the **scratch** container once with the seccomp profile swapped for
   `unconfined` to establish "works without seccomp", which turns open-ended debugging
   into a bisect. That comparison run is a throwaway and never becomes a profile.

If a syscall does need adding, that is a **`seccomp.json` edit — its own security review
and its own ADR** (Phase 4). It is the one outcome in this work item that would *weaken*
a boundary rather than extend one, which is the entire reason Q2 runs before anything is
written.

### F7 — most of the pasted research's domains are already unnecessary here

Against this repo's actual layout, of the eight-ish hosts in the incoming research:

| Host | Verdict here | Why |
|---|---|---|
| `openrouter.ai` | **already live** | `[openrouter]` exists in ALWAYS ON with a `# claude, fill in here` placeholder comment; the domain itself is uncommented |
| `registry.npmjs.org` | **gated, one-time per profile** | F1. `[npm]` is commented per ADR-0003; the first-run provider fetch goes through `scripts/with-egress.sh <p> --with npm` — the *only* sanctioned route, and it writes the audit line |
| `models.dev` | **measure first** (T01) | F3 — worthless as an entry if Bun bypasses the proxy; falls back to cache + bundled snapshot either way |
| `opencode.ai` | **gated `[opencode-install]`** | install + update check. Install happens at build time on the host network, bypassing Squid — same argument the `[antigravity]` block already makes for `agy` |
| `github.com`, `objects.githubusercontent.com` | **no new entry** | npm-package install path, not GitHub Releases; and `github.com` is an already-recorded accepted-open residual |
| `app.opencode.ai`, `api.opencode.ai`, `opncd.ai`, `mcp.exa.ai` | **stay blocked** | web UI assets, `opencode github`, opt-in session sharing, opt-in Exa MCP. `"share": "disabled"` in config makes the sharing host structurally unreachable rather than merely unlisted |

Net always-on egress delta: **zero to one host** (`models.dev`, only if T01 shows the
fetch traverses Squid). Everything else is either already there or gated.

---

## 4. Decisions — take these before implementing

| # | Decision | Recommendation |
|---|---|---|
| **D1** | Where does the OpenRouter key live? (a) `OPENROUTER_API_KEY` in `secrets.env` + `{env:OPENROUTER_API_KEY}` in `opencode.json`; (b) `/connect` + a new bind mount for `/root/.local/share/opencode` | **(a).** It is the pattern every other key here already follows (`TAVILY_API_KEY`, `CLICKUP_TOKEN`): injected at container create, chmod 600, never on argv, never in the Squid URL log. It needs no new mount, survives recreate, and sidesteps F2 entirely. `{env:…}` substitution is documented in opencode's config. (b) adds a mount whose only content is a plaintext credential |
| **D2** | Is the seeded `opencode.json` **create-only** (like `claude-home/settings.json`) or **converged** on every `up` (like skills, ADR-0005)? | **Converge**, with `reset-opencode` as the manual escape. The repo's own evidence: the myclickup permission block "sat in the template but in none of the three profiles from 2026-08-10 to 2026-08-15" because seeding is create-only. A permission file that does not reach running profiles is not a control. Carve-out: opencode keeps TUI prefs in a *separate* `tui.json`, so converging `opencode.json` clobbers less than converging Claude's `settings.json` would — confirm that during T01 before committing to it |
| **D3** | Permission posture: port Claude's deny categories, or author from opencode's key set? | **Author from opencode's key set, cross-checked against Claude's categories for coverage.** Per F5 a mechanical port produces wrong-order rules and misses that `allow` is the default. Start `"*": "ask"`, `bash: {"*": "ask", …installers: "deny", …reads: "allow"}`, `webfetch`/`websearch` decided under D4 |
| **D4** | opencode `webfetch`/`websearch`: `deny`, or `allow` and accept a second unbrokered read path? | **`deny`.** The broker exists so arbitrary page domains stay out of `allowed_domains.txt`; a second path defeats that. Revisit only if the broker turns out to be unreachable from opencode |
| **D5** | Bun quarantine: write `/root/.bunfig.toml` with `[install] minimumReleaseAge = 604800` in the image? | **Yes if T01 shows opencode's installer honours it**; if not, say so in the Dockerfile at the Gate 2 block rather than leaving the asymmetry undocumented. An unstated gap here is the exact shape of the finding that produced work/0008 |
| **D6** | Does opencode get its own audit-probe section, or extend `settings.py`? | **New probe module** (`scripts/audit/probes/opencode.py`). `settings.py`'s module docstring and `REQUIRED_DENY` are Claude-shaped; grafting a different permission language onto it makes both harder to read. Probe count in README moves off 65 — update all three references |

---

## 5. Explicitly out of scope for the first pass

- **A `deny-destructive.sh` equivalent.** opencode's plugin system could host one, but
  the hook's 95/95 test suite and its envelope regexes are Claude-tool-shaped. Porting
  it is its own work item. **State this gap in the config's comment block** — opencode
  will run in these containers with one fewer enforcement layer than Claude Code, and
  that must be written down where the next reader finds it, not discovered.
- MCP servers, custom agents, custom commands, opencode skills.
- Dashboard integration.
- Any provider other than OpenRouter.

---

## 6. Definition of done

1. `scripts/profile.sh <p> verify` passes, including a new assertion that `opencode`
   is present and reports a real version (not a broken native binary — F4).
2. `scripts/profile.sh <p> audit` passes; the new opencode probe section reports OK on
   a freshly seeded profile and DRIFT on a hand-edited one (prove the second by
   editing, not by reading the code).
3. `bash scripts/dockerfile-order.test.sh` extended and green — opencode's `npm
   install -g` locked **above** Gate 2 for the same `min-release-age` reason the other
   two are (T04).
4. `just test-offline` green (all seven suites + `check-upstreams`).
5. A real OpenRouter-backed session runs end to end in a live container under seccomp
   + `cap_drop ALL` + `no-new-privileges` (T01/T13) — per **F6**, Bun is a new runtime
   under a default-deny seccomp allowlist and has never been exercised here. A passing
   `--version` does not discharge this item.
6. Docs updated: `ARCHITECTURE.md`, `README.md` (three CLIs, probe count),
   `docs/permissions-model.md`, `docs/index.md`, `AGENTS.md` security-sensitive list,
   `.agents/skills/profile-lifecycle.md`, `.agents/skills/squid-management.md`.
