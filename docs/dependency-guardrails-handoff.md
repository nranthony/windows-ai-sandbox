# Dependency guardrails — build report, defect log, and retrospective

**Status:** complete. Phases 0–4, tasks T00–T26, merged and pushed
(`2b6971f..c0a3033`, 25 commits, 2026-07-31 → 2026-08-03).

**Audience:** an agent or engineer picking this up **without the repo or the
conversation**. Everything needed to understand what exists, why it is shaped this way,
and what is still open is written out here rather than referenced.

**Why this document exists:** the interesting output of this project was not the code. It
was **six defects that shipped looking correct** and the specific ways they were caught.
Section 7 is the part worth reading if you read nothing else.

---

## 1. The problem

**Slopsquatting.** An LLM asked for code invents a plausible-sounding package name. An
attacker registers that name and waits. The published figures that motivated this work:

- roughly **1 in 5** packages recommended by AI coding tools does not exist;
- about **43%** of hallucinated names **recur** across repeated runs — they are predictable
  enough to squat deliberately;
- roughly **half** resemble no real package at all, so Levenshtein/typo-distance scanners
  do not catch them.

The payload runs **at install time** — an npm lifecycle script, or a Python `setup.py`.
This is not the same problem as a CVE in a dependency you chose on purpose, and the
controls are different: you cannot patch your way out of a package that was malicious on
the day it was published.

Two things this work explicitly does **not** defend against, stated so nobody assumes
otherwise:

1. a patient squatter who publishes and waits out the quarantine window;
2. compromise of an already-trusted dependency.

The only control that touches those is a human deciding each new dependency deliberately —
which is what the Gate 0 work exists to force.

---

## 2. The environment (context for anyone without the repo)

`windows-ai-sandbox` is a hardened multi-profile AI development sandbox. One shared image,
many per-profile agent containers, each with persistent auth/config and Squid-gated egress.
It runs on two substrates — Windows/WSL2 with GPU, and bare Ubuntu — auto-detected.

Load-bearing properties that shape every decision below:

| Property | Consequence for this work |
|---|---|
| **Rootless Docker** — container UID 0 maps to host UID 1000 | Container-side root is fine by design; config gates are defence-in-depth, not the boundary |
| `cap_drop: ALL`, `no-new-privileges`, seccomp | Root inside the container has **no `CAP_DAC_OVERRIDE`** — this bites when reading the proxy's `0640` log |
| Agent network is `internal: true` + DNS sinkhole | No direct egress. The Squid sidecar is the only way out |
| Squid allowlist, ~53 domains | Registries are **commented out by default** — see ADR-0003 |
| `scripts/profile.sh` is the single lifecycle entry point | Never call `docker compose` directly; it owns `PROFILE`, subnet allocation, and compose-overlay layering |
| Profiles are long-lived (`restart: "no"`) | A running proxy can drift from the repo for days — this became the project's worst bug |

Three profiles were live throughout: `nranthony`, `therapod`, `fluidmomenta`.

### The five-gate model

Imported from an external design doc (retained in-repo as RFC 02) and used as the shared
vocabulary throughout. The *model* was adopted; the *system* it proposed was rejected
(ADR-0002).

| Gate | Fires at | Catches | What this repo actually does |
|---|---|---|---|
| **0 — intent** | Agent proposes an install | The name before it is resolved | Agent-notice rules + `claude-settings.json` denies + PreToolUse hook rules |
| **1 — pre-resolution** | Before any network fetch | Nonexistent/young/known-bad names | **Refused.** Gate 2 covers the same window without a service |
| **2 — resolution** | Version selection | Anything inside the quarantine window | `min-release-age` / `minimum-release-age`, asserted by `verify` |
| **3 — pre-execution** | Artifact fetched, scripts not yet run | Install-script payloads, sdists | npm `allow-scripts` empty; pnpm 10 blocks by default; Python wheels-only |
| **4 — post-install** | After execution | Detection only | **Already the network topology** — not application code |

The key insight that shaped scope: this repo *already had* Gate 4 as **prevention** rather
than detection, because of `internal: true` + the allowlist. So the work was closing cheap
gaps around an existing boundary, not building a system.

---

## 3. What exists now

### Gate 0 — intent

- **`sandbox_templates/common/agent-notice.md`** — behavioural rules, propagated into repo
  `AGENTS.md` files by `scripts/sync-agent-notice.sh`.
- **`sandbox_templates/claude/claude-settings.json`** — deny list grew **74 → 87** entries.
  Added the asymmetries: `pnpm add/install/dlx`, `yarn add/install`, `bun add/install`,
  `uv sync`, `uv lock`, `poetry add/install/lock`, `cargo add`. (npm was already covered;
  the others were not — an agent could simply use a different package manager.)
- **`sandbox_templates/claude/hooks/deny-destructive.sh`** — POSIX `sh`, two new rules:
  - **Rule 13 `manifest-dep-add` — BLOCKS.** Editing a manifest bypasses every
    command matcher, so this diffs dependency *names* in the payload against those on
    disk. Only genuinely new names block; **a version bump passes**, and that distinction
    is the merge gate.
  - **Rule 14 `docs-install-cmd` — WARNS.** Instruction files (`AGENTS.md`, `CLAUDE.md`,
    `*.mdc`, `README`) are an executable surface: an agent reads them and acts. Warn, not
    block, because false positives here are constant.
- Test suite: `bash sandbox_templates/claude/hooks/deny-destructive.test.sh` — **79/79**.

### Gate 2 — resolution quarantine

Nothing published in the last 7 days will resolve.

| Tool | Setting | Unit | Location |
|---|---|---|---|
| npm | `min-release-age=7` | **DAYS** | `/usr/etc/npmrc` (image layer; `prefix=/usr`) |
| pnpm | `minimum-release-age=10080` | **MINUTES** | `~/.config/pnpm/rc` (per-profile bind mount) |
| uv | `exclude-newer` | timestamp | documented, per project |

**`7` and `10080` are the same window. Do not "harmonise" them.** Getting this wrong is a
1440× error in one direction or the other.

Also set: `registry=` pinned, `save-exact=true`, `/etc/pip.conf` index pinned with **no**
`extra-index-url` (a dependency-confusion vector).

### Gate 3 — install-time execution

- **npm/pnpm:** `allow-scripts` empty; pnpm 10 blocks builds by default.
- **Python (ADR-0004):** wheels only. `no-build = true` in `/etc/uv/uv.toml`,
  `only-binary = :all:` in `/etc/pip.conf`. **Both**, because uv reads *no* pip config.

### Gate 4 — egress containment (pre-existing, now instrumented)

- **`proxy/allowed_domains.txt`** — registries commented out by default (ADR-0003).
- **`scripts/with-egress.sh`** — opens a named section for exactly one command, restores
  the file verbatim, flock-serialised and sentinel-tracked. Per ADR-0003 this is the
  **only route a dependency can enter a profile**, which is what makes instrumenting it a
  record rather than a sample. Each run does:
  - **pre-flight** — explicitly named packages checked against OSV; a live `MAL-` record
    refuses to open the window;
  - **bracket + snapshot** — epoch open/close, lockfile hashes, module listings;
  - **egress diff** — distinct hosts reached inside the bracket, split permitted/denied;
  - **audit record** — one JSON line to `~/.ai-sandbox/profiles/<p>/audit/depgate.jsonl`
    (host-side, so it survives `docker rm`).
  - Test suite: `bash scripts/with-egress.test.sh` — **38/38, fully offline**.

### The scanner — `scripts/depaudit.py`

Python 3.11+ **stdlib only**, read-only, never runs a package manager. A supply-chain audit
tool with its own dependency tree is self-defeating.

| Subcommand | Network | Purpose |
|---|---|---|
| `posture <path>` | no | ~21 config checks (`N*` node, `P*` python, `X*` cross-cutting, `D*` discovery) with file+line |
| `pkg <eco> <name> [ver]` | yes | OSV lookup; `MAL-` prefix is the sole BLOCK discriminator |
| `deps <path>` | yes | Enumerates every lockfile-pinned package → purl → OSV |

Surfaced as `scripts/profile.sh <p> deps [--osv|--json|--strict|--history]`.

Verdicts are deliberately narrow: a clean OSV result reports **`NO-KNOWN-MAL`**, never
"PASS". It means "nothing known yet", not "safe" — the age gate covers the unknown window.
A **withdrawn** `MAL-` record is `INFO`, not `BLOCK` (the reported May 2026 withdrawal of
157 records, which wrongly flagged FastAPI/Strawberry GraphQL/rdflib, is the worked
example and is pinned in the test corpus).

Test suite: `bash scripts/depaudit.test.sh` — **27 offline / 28 with `--online`**, over 7
fixtures.

### Tripwires — `scripts/profile.sh <p> verify`

**38 checks per profile**, tier 1, no network. Asserts every value above and fails on
drift. Split deliberately:

- **container-side** (`scripts/verify-sandbox.sh`, streamed in over stdin) — it can see
  neither the repo nor the proxy container;
- **host-side** (in `profile.sh`) — anything comparing repo state to the proxy *must* run
  here.

---

## 4. Decisions on record

| ADR | Decision |
|---|---|
| **0001** | Adopt provenance tiers: `docs/adr/` (decisions, append-only), `docs/rfcs/` (proposals with a status lifecycle), `work/NNNN-slug/` (in-flight, **deleted or archived on merge**) |
| **0002** | **What we deliberately do not build**: no Verdaccio/devpi inside the boundary, no Gate-1 HTTP service, no SARIF, no fleet mode, no Socket Firewall, no Socket API, no `osv-scanner` binary, no local OSV mirror. Each with a re-open condition |
| **0003** | Registries unreachable by default; installs open a bounded window via `with-egress.sh` |
| **0004** | Python installs are wheels-only; source builds opted into per project |

ADR-0002 is the most reusable: it exists because every refusal would otherwise be
re-proposed by the next person who reads the imported design docs and notices we did not
build it.

---

## 5. Quick reference

```bash
scripts/profile.sh <p> up|down|attach|verify|audit
scripts/profile.sh <p> deps [--osv] [--json]     # posture across a workspace
scripts/profile.sh <p> deps --history [N]        # read back install windows
scripts/with-egress.sh <p> --with pypi -- '<cmd>' # the ONLY install route
python3 scripts/depaudit.py posture <path>        # offline, any repo
python3 scripts/depaudit.py pkg npm <name>        # OSV check

bash sandbox_templates/claude/hooks/deny-destructive.test.sh   # 79
bash scripts/depaudit.test.sh [--online]                       # 27 / 28
bash scripts/with-egress.test.sh                               # 38
```

**After editing `proxy/allowed_domains.txt`:** reload with `docker restart
egress-proxy-<p>` **or** `docker exec egress-proxy-<p> squid -k reconfigure`. Both work
now — see §7 defect 5 for why that sentence has changed three times.

---

## 6. What remains

| Item | State |
|---|---|
| **Five Python projects need a wheels-only opt-out** | `job_search_agent` (forbiddenfruit, tavily), `citation_tools` (bibtexparser, sgmllib3k), `wearable_publications` (bibtexparser), `numerai` (antlr4-python3-runtime), `shrec` (python-louvain). Fix is `no-build = false` + a reason in each project's `uv.toml`. They are in the user's own repos and were deliberately not edited |
| **Two `therapod` branches unpushed** | `engine` `0aa86d5`, `app_blast` `526212c` — carry `minimum-release-age` 1440 → 10080. Until merged, the 7-day window applies only in local working copies |
| **`work/0001-dependency-guardrails/` archival** | Its own §13.1 exit rule says archive to `docs/_archive/` once T22 merged — which happened. **Blocked on re-homing D4 first**, the one open thread with no other home |
| **D4 — a second intel source, ever?** | Data-gated. Every install window now records its OSV verdicts; decide from the observed `MAL-` hit rate after ~a month of real installs. If OSV never fires, a second source is not the missing piece — the age gate is doing the work |
| **D5 — cross-port to `macolima`** | Phases 0, 1 and the npmrc layer are portable; phase 3 is not (different egress topology). Keep shell in the **bash-3.2/macOS subset** |
| `docs/incoming/` | 3 unprocessed research files. The README says triage out, don't accumulate |
| G10 one level deeper | Per-member `.npmrc` in monorepo children not detected |
| X04 coverage | Does not scan `apps/*/README.md` |

---

## 7. Every defect, and how it was caught

**This is the substance of the project.** Sixteen defects; the notable thing is that
**not one was caught by reading code.**

### The six that shipped looking correct

| # | Defect | Why it looked fine | Caught by |
|---|---|---|---|
| 1 | **pnpm silently ignores `minimumReleaseAge`** in an rc file — the key must be kebab-case `minimum-release-age` | The config file looked exactly right and did nothing. `pnpm config get` returned `undefined` | The `verify` tripwire, on its first run |
| 2 | **`depaudit` N01 inverted** — FAILed repos that had *no* install-script allowlist | Reasoned "an allowlist is good". Reality: **pnpm 10 blocks by default; the allowlist is the hole.** The suggested fix would have made repos *less* safe | Measuring against a live pnpm |
| 3 | **`depaudit` N02p inverted** — rejected `minimum-release-age` in `.npmrc` | False analogy to `supportedArchitectures`, which genuinely *is* ignored there. Scalar settings survive that path; nested maps do not | Measuring with a 10-year window |
| 4 | **Lockfile parser put peer-dependency suffixes in package names** — pnpm v9 keys look like `@scope/pkg@1.2.3(peer@4.5.6)`; splitting on the last `@` yields `@scope/pkg@1.2.3(peer` | **121 of 869 entries** were queried under names OSV cannot match → **all reported clean** | A fixture; post-fix the parser reproduced an independent audit's own figures exactly |
| 5 | **The allowlist bind mount went stale on ordinary git operations** | `docker-compose.yml` mounted `allowed_domains.txt` as a **single file**, which pins an inode at container start. Any `git checkout/merge/pull/stash` replaced it; the container stayed on the deleted inode, and `squid -k reconfigure` re-read the stale copy and **exited 0**. `verify` reported **"in sync"** because the merge changed only comments, which its diff strips | An install failing with `tunnel error: unsuccessful` — an error naming nothing |
| 6 | **`depaudit` P08 over-reported by ~87×** — counted packages that *publish* an sdist rather than those with **no wheel** | Almost every PyPI package publishes an sdist alongside wheels; uv installs the wheel. Measured: **522 of 565** "have an sdist", **6** are sdist-only. `dashboard` was recorded as "45 sdists" — its true count is **zero** | Re-measuring when the number was finally used to decide something |

**Defect 5 is the most serious.** It meant the repo's allowlist was **advisory, not
authoritative**: tightening it in git did not take effect on a running proxy. It had
already happened once before (G9 — all three proxies still tunnelling a domain the repo had
gated) and the first fix was *better documentation*. The class only disappeared when the
mount changed from a file to a directory.

**Defect 6 is the most instructive**, because it *had a passing test*. The fixture asserted
`P08 == WARN`, and P08 did emit `WARN` — for the wrong reason, on the wrong packages. It
did not fail; it produced a confident number that **stopped work for days**.

> **A test that asserts a status but never checks which items produced it cannot catch a
> counting bug.**

### Refuted claims (recorded because the negative result is the finding)

| Claim | Verdict |
|---|---|
| `squid -k reconfigure` kills the proxy (SIGHUP → exit 129) | **Refuted.** squid is **not PID 1** — it is a child of `entrypoint.sh`, handles SIGHUP as a reconfigure, and the container survives. A whole task (T17) was dropped |
| `supportedArchitectures` in `.npmrc` works with the right notation | **Refuted for both notations.** Measured: installed `@esbuild/*` went 1 → 4 via CLI/`pnpm-workspace.yaml`, and stayed 1 for either `.npmrc` spelling. Removed entirely |
| Blanket wheels-only is not viable here | **Refuted** — see defect 6 |

### The rest

| Defect | Note |
|---|---|
| `awk` function locals are **global** unless declared as extra parameters — `emit()` assigned to `i`, the caller's `for (i=…)` counter | **Infinite loop.** Caught by the new test suite on its very first execution |
| Squid logs `epoch.milliseconds`; `date +%s` truncates. `$1 <= end` dropped every request in the closing fractional second | A real `uv pip install six` reached pypi.org at `.063` past close; the audit record said **0 hosts**. Under-reporting is indistinguishable from a clean run |
| `verify` printed a host-side WARN then `0 warnings` | The tally comes from the container-side script; host-side checks ran in `profile.sh` and were never counted. **This is how the stale-inode proxies survived a full post-merge verification pass** |
| Dependency-name extraction was line-oriented | Missed every compact manifest. Fixed by normalising on `{}[],` first. The *failing merge-gate test* is what caught it |
| `docker exec -u root` cannot read `access.log` | `cap_drop: ALL` leaves `CapEff 0xc0` — no `CAP_DAC_OVERRIDE` against the `0640 proxy:proxy` file. Must use `-u proxy` |
| T24 was specified in the wrong file | `verify-sandbox.sh` is streamed *into* the agent container and can see neither the repo nor the proxy. Moved host-side |
| `N06`/`X07` tested for `.git` at the scan root | Blind to every monorepo member. Now `git rev-parse --is-inside-work-tree` |
| `ini_get` missed npm's `key[]=value` array syntax | `N11` had never fired on a real exemption list |
| `/usr/etc` does not exist in the base image | Build failure; needs `mkdir -p` |
| **Dockerfile layer order is load-bearing** | The npmrc layer must come *after* the `claude`/`agy` install — `min-release-age` applies at **build** time too, so writing it earlier makes `@anthropic-ai/claude-code@latest` unresolvable whenever the newest release is inside the window. A self-inflicted build break |
| A project `.npmrc` silently overrides the global quarantine | Precedence is `cli > env > project > user > global`. Detected by `verify`, which now **compares** rather than merely reporting presence |
| pip's wheels-only refusal message | Reads `Could not find a version that satisfies the requirement X (from versions: none)` — **indistinguishable from the package not existing**, i.e. exactly like a slopsquat miss. uv names the real reason |

### Tooling traps that cost time (not product defects)

`zsh` does not word-split unquoted `$var`; a heredoc and a pipe both claim stdin;
`docker cp` cannot write into a tmpfs-masked `/tmp`; `/tmp` is `noexec`, which confounds
any binary-execution check; `importlib.util` loading needs the module in `sys.modules`
before `@dataclass` resolves; `pkill -f <pattern>` **matches its own command line** and
kills the shell running it; `git merge -F -` does not read stdin the way `git commit` does.

---

## 8. What is in the persistent memory store, and why

Thirteen memories. The ones specific to this work:

| Memory | Why it exists |
|---|---|
| `proxy-allowlist-edit-needs-restart` | **Now marked RESOLVED.** Originally: edits need a container restart, not `reconfigure`. The directory mount removed the cause; the slug is historical and four other memories link to it, so it was rewritten rather than renamed |
| `dashboard-reload-sighup-kills-proxy` | **Marked REFUTED.** squid is not PID 1. Kept so the mechanism is not re-derived |
| `proxy-recreate-network-wedge` | Recreating the proxy without `SANDBOX_OCTET` half-attaches it; `profile.sh` is immune |
| `claude-autoupdate-breaks-native-binary` | In-container self-update reinstalls without `--allow-scripts`, blocking postinstall. Presents as a multi-VS-Code bug and is not |
| `stale-db-container-network-not-found` | `up` fails when an old `postgres-<p>` is pinned to a recreated network |
| `per-profile-subnet-octet` | How concurrent profiles get distinct `172.30.x.0/24` subnets |
| `portable-shell-for-sister-repo` | Cross-ported shell must stay in the bash-3.2/macOS subset |

**Two are process memories, from direct user correction, and they generalise:**

- **`next-step-suggestions-must-mark-tangents`** — the user acts on whatever appears in the
  "suggested next step" slot. Mid-project they asked *"are we creeping off of path here?
  … I went with them thinking you know better."* Off-plan items must be labelled as
  tangents **with their cost**, never presented in the recommendation slot.
- **`defer-decisions-to-their-phase`** — hold open design decisions until the phase that
  needs each one; work the phases together rather than front-loading choices. This
  directly produced the right outcome: D1 was answered by observing the deployed state, and
  T23 was answered by re-measuring rather than by the assumption recorded months earlier.

A third piece of feedback did not become a memory but should be recorded: the user
interrupted a tool call to ask whether "testing known bad packages" was actually
*executing* anything. It was a name lookup only. **Explain what a command does before
running anything that references malicious packages** — the word "test" is not
self-explanatory when the subject is malware.

---

## 9. Retrospective — what transfers to other work

**1. Measure; do not reason. Then re-measure before "fixing" a measurement.**
Every defect above was found by running something. Not one was found by review. Two checks
shipped *inverted* — they would have made repos less safe to satisfy the scanner — and both
came from plausible reasoning about how a tool "should" behave.

**2. The dangerous failure is the silent one.**
Rank by how they present, not by severity:

- an under-reporting audit log is **indistinguishable from a clean run**;
- a config with a wrong key (`minimumReleaseAge` vs `minimum-release-age`) **looks correct
  and does nothing**;
- `squid -k reconfigure` **exits 0** having applied nothing;
- a path constant that drifts makes four separate checks **skip themselves forever** rather
  than error.

Design so that broken means *loud*. Where that is not possible, add a test that pins the
discriminating case.

**3. A passing test is not evidence the check is right.**
Defect 6 had one. Assert on **which items** a check produced, not merely its verdict.

**4. Detection is not a fix. Root-cause the class.**
The stale-mount bug was "fixed" twice — first with better docs, then with two detectors —
before anyone asked *why the condition kept arising*. The answer was one line of compose
config. **A mitigation that requires a human to remember an invisible coupling is not a
mitigation.**

**5. A permanently-firing warning is furniture.**
The first project-`.npmrc` check warned on the *presence* of any override, so a repo doing
exactly the right thing got the same warning as one switching the gate off. It fired on
every profile forever and taught everyone to ignore it. Rewritten to compare against the
global baseline and warn only on a genuine weakening.

**6. Write down units, and assert them.**
npm counts **days**, pnpm counts **minutes**. `7` and `10080` are the same window. A
suffixed pnpm value (`"0s"`, `"7d"`) is worse than zero: it yields `NaN` → `Invalid Date` →
**every version rejected**, which fails closed and presents as a broken registry.

**7. Documentation that has flipped twice should explain, not instruct.**
The guidance on `squid -k reconfigure` went "preferred" → "never use it" → "fine again".
The command was correct the whole time; the mount was broken. Rules invite reversal;
mechanisms do not.

**8. Record refusals as first-class decisions.**
ADR-0002 (what we deliberately did *not* build) has already prevented re-litigation twice.
Without it, every reader of the imported design docs re-proposes the same rejected system.

**9. Independent review catches what proximity hides.**
A second model reviewed the mount fix and caught that the container-side path appears in
**five** places, each of which fails *silently* on a mismatch. That gap would have taken
down the entire install route on rollout. The fix now has a regression lock covering all
five.

**10. Scope discipline is a user-facing behaviour, not an internal one.**
The `supportedArchitectures` investigation was a genuine tangent that consumed real time
because it was presented as the natural next step. It ended in a correct result — the
setting is inert in `.npmrc`, drop it — but it was not on the plan's path.

---

## Appendix — task ledger

| ID | Task | Outcome |
|---|---|---|
| T00 | Re-baseline container probe | Done — versions moved measurably in 24h; re-run per session |
| T01 | Reproduce G1 | **Refuted** — T17 dropped |
| T02 | Rules into `agent-notice.md` | Done (phase 0) |
| T03 | Deny-list symmetry | Done — 74 → 87 |
| T04 | `manifest-dep-add` hook rule | Done — **blocks**; version bumps pass |
| T05 | Docs install-command rule | Done — **warns** (deviation from plan, documented) |
| T06 | Hook tests | Done — 61 → **79** |
| T07 | `/usr/etc/npmrc` + `/etc/pip.conf` | Done — layer order load-bearing |
| T08 | Validate the autoupdater still works | **Passed** — gates T07 |
| T09 | Allowlist lifecycle + header | Done — D1 = strict |
| T10 | pnpm quarantine in state init | Done — kebab-case fix |
| T11 | uv `exclude-newer` documented | Done |
| T12 | Tier-1 Gate-2 tripwires | Done — 31 → 35 checks |
| T13 | `depaudit posture` | Done — stdlib-only |
| T14 | `profile.sh deps` | Done |
| T15 | Fixtures + corpora | Done — found 2 more bugs immediately |
| T16 | `depaudit pkg` + OSV `MAL-` | Done |
| ~~T17~~ | ~~Fix `reload_proxy`~~ | **Dropped** — G1 refuted |
| T18 | Window pre-flight | Done — refuses on live `MAL-`, fails open on UNKNOWN |
| T19 | Bracket + snapshot | Done |
| T20 | Egress diff | Done — `-u proxy`; bracket bug found and locked |
| T21 | Filesystem diff | Done — folded into T19 |
| T22 | Persist to host audit log | Done — + `deps --history` |
| T23 | Python wheels-only | Done — ADR-0004; gating number was an 87× over-report |
| T24 | Allowlist drift tripwire | Done — host-side |
| T25 | Stale bind-mount detection | Done — now a regression lock |
| T26 | Directory mount | Done — removed the class |

**Final state:** hooks 79/79 · depaudit 27/27 offline, 28/28 online · with-egress 38/38 ·
`verify` 38/38 with 0 warnings on all three profiles.
