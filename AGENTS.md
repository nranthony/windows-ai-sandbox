# windows-ai-sandbox

Hardened multi-profile AI development sandbox: one shared image, many
per-profile agent containers, each with its own persistent auth/config and
Squid-gated egress. Runs on **two substrates** — Windows/WSL2 with GPU, and
bare Ubuntu Linux without — auto-detected by `scripts/profile.sh` (signal:
`/dev/dxg`; override `SANDBOX_GPU=0|1`). The security boundary (rootless
Docker: container UID 0 ↔ host UID 1000) is identical on both.

**This is security-critical infrastructure. Source of truth is config, not
code**: `docker-compose.yml`, `seccomp.json`, `proxy/`, `sandbox_templates/claude/`.

## System architecture

Diagrams, network model, state layout, security posture, repo map:
[ARCHITECTURE.md](ARCHITECTURE.md).

## Subprojects

Implementation details stay local to keep this file small:
- **Control dashboard** (Streamlit): [dashboard/AGENTS.md](dashboard/AGENTS.md)
- **CUDA verification** (uv project): [container_testing/AGENTS.md](container_testing/AGENTS.md)

## Golden rules

1. **`scripts/profile.sh` is the single lifecycle entry point.** Do NOT call
   `docker compose` directly, hand-set `COMPOSE_PROJECT_NAME`, or spawn
   containers outside it — it owns the `PROFILE` export, per-profile subnet
   allocation, and compose-overlay layering. If a capability is missing,
   extend `profile.sh`; never bypass it. (The `justfile` is a thin alias
   layer over it and holds no logic.)
2. **The base compose stays substrate-neutral.** GPU/WSL wiring lives ONLY in
   `docker-compose.wsl-gpu.yml`. Never add devices, host mounts, or
   WSL-specific paths to `docker-compose.yml` — it must come up on bare Linux.
3. **Match existing patterns** in the file you are editing over external
   style guides. Cross-check, but never blind-copy, from the sibling
   `macolima` repo (`docs/sibling-repo-relationship.md`).

## Security-sensitive changes

These files carry the sandbox's guarantees:

- `Dockerfile`
- `docker-compose.yml` **and** `docker-compose.wsl-gpu.yml` (overlay edits add
  devices/mounts without touching the base — same scrutiny)
- `seccomp.json`
- `proxy/squid.conf` + `proxy/allowed_domains.txt`
- `sandbox_templates/claude/claude-settings.json` + `sandbox_templates/claude/hooks/`
  (the hook under `hooks/` is now shared by BOTH agents — see below). Since
  [ADR-0007](docs/adr/0007-policy-templates-are-source-of-truth-for-every-agent.md)
  the settings template CONVERGES: an edit here reaches every profile on its
  next `up`, so it is live policy, not a seed. **The two halves reach a
  container by different routes and that is the recurring confusion**: the
  policy file converges on `up`, the hook ENGINE is baked into the image and
  still needs `build` + recreate.
- `sandbox_templates/antigravity/` — the `agy` half of the same policy
  ([ADR-0006](docs/adr/0006-antigravity-is-two-layer-like-claude.md)). The
  **static** `permissions.deny` there is the load-bearing layer, not the hook:
  a workspace `.agents/hooks.json` outranks the global one and can disable the
  hook **by name** (measured, `work/0010` Phase 0), while nothing in a workspace
  can reach `settings.json`.
- `scripts/profile.sh`, `scripts/init-profile-state.sh`, `scripts/verify-sandbox.sh`
  (the credential.helper scrub both run on every `up` is a load-bearing defense
  against VS Code injecting host-reaching git credential helpers — audit
  Finding B/C in `docs/vscode-integration-security.md`; never remove it as
  "redundant")
- `scripts/run-ephemeral.sh` (raw `docker run` — mirrors compose hardening by hand)
- `scripts/with-egress.sh` — per [ADR-0003](docs/adr/0003-strict-egress-default.md)
  this is the **only** route by which a dependency can enter a profile. It widens
  the allowlist, so a bug here is an egress hole; and it writes the install audit
  log, so a bug here silently *under-reports* — which reads exactly like a clean run.
  It also **is** the Python age gate: `exclude-newer` takes a timestamp, not a
  duration, so no static config can express "7 days"; this script computes it per
  window and injects `UV_EXCLUDE_NEWER`. Env beats a project `[tool.uv]`
  exclude-newer (measured, uv 0.12.5) — the opposite of Gate 2 and Gate 3, where
  the project file wins, so do not generalise between them. `--allow-fresh
  "<reason>"` is the only way off it and the reason is mandatory and recorded.
- `scripts/vendor-tools.sh` — per [ADR-0014](docs/adr/) (channel-side, myclickup
  work/0016) this is the route by which vendored payloads enter the build
  context: the wheel bakes into the image, the skills converge into every
  profile. A bug here is unverified content inside the boundary, arriving
  through the door meant to check it. It verifies every hash **before copying
  anything**, asserts manifest paths stay inside the channel root, and invokes
  the channel's own `bin/dirhash.py` rather than reimplementing a tree hash.
- `sandbox_templates/bin/webfetch` — the **only** sanctioned route by which the
  agent reads the open web (`docs/web-read-broker.md`): every backend is a
  hosted reader whose exact API host is allowlisted, so the arbitrary-URL egress
  happens on the vendor's side. A bug here is quiet — a backend that returns
  nothing reads as "empty page", and a key placed in a URL is visible only in
  Squid's access log. Keys come from the environment ONLY, never argv.

Any change to them requires:
1. The commit message states the security impact.
2. `scripts/profile.sh <profile> verify` (tier 1) passes; run
   `scripts/profile.sh <profile> audit` (tier 2) for anything non-trivial.
3. Affected docs updated (ARCHITECTURE.md, `sandbox-hardening-package.md`).

Hook edits additionally require
`bash sandbox_templates/claude/hooks/deny-destructive.test.sh` (207/207). That
script is now ONE engine serving TWO agents, selected by `--dialect=`, so a rule
added for either protects both — and its two failure postures are deliberately
OPPOSITE: claude fails **open** (its `permissions.deny` is underneath it),
antigravity fails **closed** (for reads the hook IS the control, and `agy`
blocks a misbehaving hook regardless). Claude's pass-through `{}` is a **deny**
to `agy`, so the antigravity pass must stay an explicit `{"decision":"allow"}`.
Unifying any of that is the likeliest way to turn this into a hole; the suite
locks all three.
The engine has **three tiers**, not two — warn, ask, deny (work/0004) — and the
ask tier is dialect-branched for the same reason the postures are: claude emits
`permissionDecision:"ask"` (re-prompts), `agy` emits `decision:"force_ask"`,
because `agy` caches a plain `ask` approval as a permanent Always-Allow grant,
so `ask` there would mean "prompt once, then delete freely forever". Measured,
not assumed: headless and in subagents a claude `ask` is a **deny carrying the
reason**, and it **outranks a static `permissions.allow` entry** — which is what
lets the deletion rules narrow `Bash(git checkout:*)` and `Bash(git stash:*)`
without either static list being edited. An **unknown `--dialect=` is fatal**
(stderr + exit 2, no stdout): it used to coerce to claude, which would emit
claude-shaped output to the third agent (opencode, work/0009) and leave the
guardrail installed and inert. Adding a dialect means an arm in each of
`emit_pass`/`emit_block`/`emit_ask`/`emit_trap` plus an adapter; the suite's
unknown-dialect assertions say if one is missing.
Edits to `sandbox_templates/antigravity/`, to either static policy list, or to
`converge_agent_policy` / `AGENT_POLICY_DESCRIPTORS` in `scripts/profile.sh`
require `bash scripts/agent-policy.test.sh` (53/53, offline — no docker, no
`agy`, no `claude`). It diffs the two policy lists EXACTLY, in both directions,
for `allow`/`ask`/`deny` alike, with no exception list, because two hand-edited
lists that must agree will drift — `pnpm dlx` and its five fetch-and-run
siblings already did exactly that, and the 2026-08-24 myclickup promotion is the
same shape in the other direction. It also locks the convergence for BOTH agents
([ADR-0007](docs/adr/0007-policy-templates-are-source-of-truth-for-every-agent.md)):
the two write modes must stay OPPOSITE — claude overwrites because its
preferences have repo-local files to live in, `agy` merges because it has none
and what it stores there is functional state — and unifying them either destroys
live `agy` state or lets a stale Claude key survive enforcement. Convergence is
file-scoped in both directions: `gemini-home/config/` holds live `agy` state
(`config.json`, `mcp_config.json`, `projects/`), `antigravity-cli/settings.json`
is shared with the running agent, and `claude-home/` holds files the sandbox
never seeded, so applying ADR-0005's mirror semantics anywhere here is silent
data loss on a routine `up`. Three more locks are recovery-shaped: the claude
overwrite must capture what it drops **including the content diff of an owned
key** (a top-level capture alone misses an in-session `ask`→`allow` promotion
landing in `permissions` — measured live in a profile); the warning must go
QUIET when the captured set has not changed (claude rewrites `model` every
session, and a warning that always fires is not read); and a clean run must not
BLANK the previous capture, or the operator gets exactly one `up` to notice.
Three more lock the PRESERVE list, which is four keys as of 2026-08-24
(`skipAutoPermissionPrompt`, `model`, `effortLevel`, `agentPushNotifEnabled`) and
has TWO halves that are easy to implement as one: a **live** value must survive
converge, AND a live file that **lacks** the key must take the template default
(`opus`/`medium`/`false`). Implementing only the first leaves every fresh profile
— and every profile the pre-decision converge had already stripped — unset
forever. The preserved keys are deliberately NOT owned keys: tier-1
`check_agent_policy_sync` compares the owned list only, and tier-2's
`template_diff` strips the preference set from **both** sides now that the
template carries defaults (stripping only `live` makes the template's
`"model": "opus"` read as DRIFT on every profile where the operator picked
something else). `converge --defaults` is the opt-out and captures what it
replaced under `preference_resets`.
Edits to `scripts/depaudit.py` require `bash scripts/depaudit.test.sh` (56/56
offline; `--online` adds the OSV corpus). Two of its assertions are regression
locks for checks that shipped **inverted** — read the header before changing them.
Edits to `scripts/with-egress.sh` require `bash scripts/with-egress.test.sh`
(82/82, offline — no docker or network). It covers five parsers — two here and
`list_denied_domains` in `profile.sh`, which reads the same file — locks a
bracket bug that made a real install log zero egress, and asserts the
container-side allowlist path agrees across all five places it appears. Edits to
either script's allowlist parsing run it.
It also owns the **Gate 3 drift lock**: `gate3_scan_file` (the section-aware
parser for project-level `no-build = false` / `no-binary`) exists byte-identically
in `with-egress.sh` AND `verify-sandbox.sh`, because the latter is streamed into
the container over stdin and can source nothing. The suite extracts both bodies
and diffs them exactly. Edit both or neither. Its section scope is the point: a
line-grep also matches `no-build = false` under `[tool.hatch]` or behind a `#`,
and a reported opt-out that does not exist sends someone hunting for it.
Edits to the `Dockerfile` require `bash scripts/dockerfile-order.test.sh` (8/8,
offline). The install-layer order is a load-bearing chain — beads < claude/agy <
npmrc (Gate 2) < uv/pip (Gate 3) — because `min-release-age` applies at **build**
time too: write it above the CLI install and `@anthropic-ai/claude-code@latest`
becomes unresolvable whenever the newest release is inside the quarantine window.
That break is intermittent (it depends on when upstream last published) and
surfaces on a routine `--refresh-ai`, not just a cold build.
Edits to `converge_skills` or the `converge` subcommand in `scripts/profile.sh` require
`bash scripts/profile-skills.test.sh` (24/24, offline — no docker). Three of its
assertions are regression locks: a `<name>.bak.<stamp>`
inside `claude-home/skills/` is a second LIVE copy (for a skills-dir plugin the
backup WINS the name race and the fresh copy reports `✘ Not loaded`); a
directory the sandbox never seeded must survive convergence because `claude
plugin init` scaffolds into `~/.claude/skills/<name>/`; and convergence MIRRORS
a skill rather than merging into it — a file deleted inside a skill must vanish
from the profile, including at depth and behind a dot-directory (all three live
profiles carried phantom skill copies four levels down for three upstream
releases). See [ADR-0005](docs/adr/0005-skill-templates-are-source-of-truth.md),
extended to every agent's POLICY by
[ADR-0007](docs/adr/0007-policy-templates-are-source-of-truth-for-every-agent.md).
Edits to `scripts/vendor-tools.sh` require `bash scripts/vendor-tools.test.sh`
(65/65, offline — no docker, no network, no real channel). It is the door every
vendored payload now enters through, so three of its assertions are regression
locks, each proven to bite by mutation: **nothing is copied when any hash fails**
(the gate runs over every artifact before the first file moves — a per-artifact
gate leaves a half-updated image and still exits non-zero, so the failure looks
handled); **progress output must not reach stdout** (`verify_all` returns the
manifest table on stdout, so a progress line written there is captured *into the
data* — measured during development: the verified-hash lines vanished from the
terminal and reappeared as bogus artifact rows the mirror loop skipped in
silence); and **an unknown artifact kind FAILS rather than skipping**, because a
kind the script has not been taught is content it cannot verify.
Three more lock the content half: **a wheel that disagrees with the
`source_commit` it claims FAILS** even though every hash matches (only the
content diff can see that, which is the entire argument for keeping it); **a
member checkout ahead of the published commit is NOT drift** (the vendored copy
tracks what the channel published, so the diff is against that commit, never the
member's HEAD — otherwise the check reddens on an ordinary state); and **a
prefix over-match counts as covered** in `--permissions` (`statuses` riding
`status:*`), because a check that cries wolf on its first run is a check that
gets ignored.
Edits to `sandbox_templates/bin/webfetch`, to any broker host in
`proxy/allowed_domains.txt`, or to `sandbox_templates/common/secrets.env.template`
require `bash scripts/webfetch.test.sh` (90/90, offline — no docker, no
network, no key). It runs the broker as a real subprocess with `urlopen`
shimmed, so its locks are measured: **no request leaves when a key is
missing**; **keys travel in headers, never in URLs** (Squid logs URLs, so a
key in a query string is a leak the agent cannot see); **every host the broker
calls is an exact live allowlist line, and the hosts it must never reach are
not** (TinyFish's Agent/Browser APIs share the key with its free Search/Fetch —
a cloud browser the model steers is a write surface, and `.tinyfish.ai` as a
wildcard would open it); **every env var it reads is named in the secrets
template** (a plausible synonym reads as unset); and **the untrusted banner is
the first line on stdout with hostile text passing through verbatim after it**
— the banner marks the boundary, it does not filter, and a "fix" that filtered
would hide the injection from the reader rather than from the model.
Edits to `sandbox_templates/common/agent-notice.md` require
`bash scripts/agent-notice.test.sh` (13/13, offline). The notice is the one file
here whose text is read from filesystems where this repo does not exist —
`sync-agent-notice.sh` deploys it into every consumer repo's `AGENTS.md` and
every profile's `claude-home/CLAUDE.md` — so two defects are invisible from
inside this repo, where every path resolves. It locks both: **no repo-relative
path** (`scripts/with-egress.sh` shipped in it for months and resolved to
nothing inside `/workspace/<repo>/AGENTS.md`), and **no host-side mechanism**
(that same reference was worse than a dead path — the notice exists to say
"treat a denial as a human step, don't hunt for a workaround", and naming a
script the agent has no route to turns "ask the human" into "run this"). The
rule is frame-of-reference, NOT repo containment: `/usr/lib/wsl/lib/nvidia-smi`,
`/root/.claude` and `~/.local/bin` are all correct and all outside every repo.
Both defects were found by an outside audit — a consumer repo running
`/myconv:apply-conventions` — never by anything here, which is why they are
locked now. The suite also asserts every fetch-and-run form the notice names has
a real `permissions.deny` entry behind it: a notice promising a denial that does
not exist is never tested, because the agent reads it and does not attempt.

Edits to the scanned surfaces in the public-repo check below require
`bash scripts/private-names-check.sh`; it prints a loud `[SKIP]` and exits 0
when `.private-names.local` is unconfigured, so a green run there is not
proof of coverage — see "Public-repo constraints".

`just test-offline` runs all ten suites, then `just check-upstreams`. Verify
additionally asserts no `*.bak*` sits beside the seeded skills: `converge_skills`
prunes only `*.bak.*`, so the unstamped form survives it.

## Boundary monitors — every vendored payload gets a detector here

`just check-upstreams` answers "am I current with my upstreams?" through a
single monitor, `tools-check` (`scripts/vendor-tools.sh --check`), which covers
every artifact the depot channel carries. **Add a line to it whenever a new
upstream payload is vendored into this repo by any other route.**

It asks two questions per artifact and both are load-bearing: does `VENDORED.lock`
still match what the channel *publishes* (hash), and does the artifact still match
the *source commit it claims* (content, by extraction, whenever the member
checkout is reachable — `HASH-ONLY` stated aloud when it is not). A hash cannot
answer the second; dropping the content half would move a security-critical
verification from this consumer to trusting the producer's gate, a transfer of
trust dressed as a simplification. The content diff runs against the PUBLISHED
commit, never the member's HEAD, because a member ahead of the channel is an
ordinary state and not drift.

Until 2026-08-16 this was three recipes over two per-payload vendor scripts
(`skills-check`, `vendor-check`). They retired with those scripts once the
channel was proven equivalent by a zero content diff.

The rule it encodes: *the detector belongs on the side that owns the stale copy.*
It did not, and that is the whole reason the myconv payload sat three releases
behind for days. `just check-vendored` lives in agentic-conventions and tells
**that** repo it is ahead; nothing here said **this** repo was behind. The two
per-payload monitors that preceded `tools-check` also failed in opposite
directions when unconfigured — the myclickup one died (false alarm),
`check-vendored` exited 0 (false pass) — so neither could be wired into anything
automatic.

**Three states, three outcomes.** The channel pointer resolves from `$DEPOT_DIR`
or a gitignored `.depot-dir.local`; the member checkouts used by the CONTENT half
still resolve from `$MYCLICKUP_DIR`/`$CONVENTIONS_DIR` or `.myclickup-dir.local` /
`.conventions-dir.local`. For every one of them the two halves of "absent" are
NOT the same:

| State | Outcome |
|---|---|
| nothing configured | loud `[SKIP]`, exit 0 — ordinary: the myclickup payload is gitignored and its source repo is private |
| **configured, target missing** | **FAIL, exit 1** — a broken pointer, never ordinary |
| configured and present | compare |

Collapsing those two is not hypothetical: on 2026-08-14 both source repos moved
under the cross-repo channel root, both pointers still named the old locations,
and `test-offline` went **green** over a real three-release wheel drift it had
been reporting red the day before. Neither script guesses a fallback path any
more, for the same reason — a guess makes "never configured" and "moved away"
print the same line. One asymmetry is deliberate: an absent MEMBER checkout
degrades the content half to `HASH-ONLY` rather than failing, because the hash
half still ran — but it says `HASH-ONLY` out loud and counts it on the closing
line, so partial coverage never reads as full.

**A skip is not a pass.** The aggregate recipes say so on their closing line
rather than claiming full coverage, because the failure that started this was a
green summary printed over a check that never ran.

The monitor is offline — it reads a sibling checkout, no network and no
docker — which is why `test-offline` can call it. A real drift therefore turns
`test-offline` red, deliberately: the alternative is the invisible drift this
exists to prevent. Clear it by re-vendoring, not by muting the check.

**`proxy/` is mounted as a DIRECTORY (`./proxy:/etc/squid/host:ro`), and that is
load-bearing.** A single-file bind mount pins an inode at container start, so
`git checkout`/`merge`/`pull`/`stash` — ordinary workflow, not editor quirks —
left running proxies unable to see host edits at all, with `squid -k reconfigure`
re-reading a deleted copy and exiting 0. The allowlist was effectively advisory:
tightening it in git did not take effect. Never revert this to a file mount;
`verify` fails loudly if you do. Changing the mount target means changing the
`acl` in `proxy/squid.conf` and the `PROXY_ALLOWLIST` constant in `profile.sh`,
`with-egress.sh` and `dashboard/src/lib/docker_client.py` — every one of those
fails *silently* on a mismatch, so the test suite locks them together.

## Container state placement

Where a piece of state lives decides whether it survives `docker rm`. The rule:
**if losing it would hurt, it does not live in a container's writable layer.**

| State | Home | Survives `docker rm` |
|---|---|---|
| Source code | host bind mount, in git | yes |
| Python env | `.venv` inside the workspace | yes |
| Models / large data (Ollama store: shared `~/.ai-sandbox/models/ollama`, mounted read-only — the runtime never writes weights) | host dir, gitignored | yes |
| DB data | named volume | yes |
| pip / apt / HF caches | writable layer — disposable by design | no |

A stopped container keeps its whole copy-on-write layer and nothing reports the
cost; six stale VS Code devcontainers reached 149GB here before anyone looked.
`scripts/docker-gc.sh` (`just docker-gc`) sweeps that up — monthly is about
right. It deliberately splits what may be automated from what may not:

- **Auto-prunable**: stopped containers, BuildKit cache. Nothing durable is
  there if the table above is respected.
- **Report-only, human decides**: images and volumes. Volumes are the only
  place durable data lives. And `docker image prune` is *not* safe to automate
  here — pulling a digest-pinned `repo:tag@sha256:...` (as `docker-compose.yml`
  does for postgres/mongo/squid) stores the image with NO tag, so Docker
  classifies it as dangling and an unfiltered prune deletes it. That is why the
  post-build prunes in `scripts/profile.sh` are filtered to the `sandbox.image`
  label set in the `Dockerfile` — never unfilter them.

Never `docker commit` a container as a backup: it captures caches, not data,
and cannot be diffed or restored selectively. Back up the source dir or volume.

## Public-repo constraints

This repo is **public**; real profile names double as real client/project
names. The standard is **searchable, not "present at all"**
([0007-genericise-public-identifiers](docs/_archive/0007-genericise-public-identifiers-spec.md), archived on merge):
high-visibility surfaces — README, ARCHITECTURE, this file, `justfile`,
`scripts/`, `sandbox_templates/`, `docs/index.md`, `docker-compose*.yml`,
`Dockerfile`, `seccomp.json`, `proxy/` — must carry no client name,
case-insensitive. Archived narrative (`docs/_archive/`), RFCs, and `work/*/`
are deliberately KEPT as historical record — rewriting them to look tidier is
worse than the disclosure, and no git history is rewritten either. Evidence-
bearing uses are also kept: `proxy/allowed_domains.txt`'s provenance comments
name which account a workspace ID belongs to and why one was unverified, and
the name there IS the checkable evidence, not a leak. `scripts/private-names-check.sh`
enforces the searchable standard on the scanned surfaces, reading the name
list from a gitignored `.private-names.local` (owner-provided; loud `[SKIP]`,
exit 0, when unconfigured) — wired into `just test-offline`.

## Operational guides (host-agent skills)

- Profile lifecycle, builds, DBs, ephemeral runs, agent-skill seeding:
  [.agents/skills/profile-lifecycle.md](.agents/skills/profile-lifecycle.md)
- Verify / audit / trivy tiers:
  [.agents/skills/security-audit.md](.agents/skills/security-audit.md)
- Egress allowlist edits + with-egress:
  [.agents/skills/squid-management.md](.agents/skills/squid-management.md)

Deep-dive docs are indexed in [docs/index.md](docs/index.md).

## Where things live

Nothing below `docs/` or `work/` is auto-loaded — this index is how it is found.
Before starting work, check `docs/adr/` for decisions constraining the area, and
`work/` for anything already in flight on it.

| The question | Home |
|---|---|
| System map & boundaries | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Why a decision was made | [docs/adr/](docs/adr/) — append-only; supersede, never delete |
| Proposals under discussion | [work/](work/) — `NNNN-slug/spec.md`, `Draft → Accepted → ADR-NNNN \| Rejected` (`docs/rfcs/` closed 2026-08-25, [ADR-0010](docs/adr/0010-one-proposal-home-close-the-rfc-tier.md)) |
| What is in flight right now | [work/](work/) — `NNNN-slug/`, **archived to `docs/_archive/` on merge** |
| Raw unprocessed input | [docs/incoming/](docs/incoming/) — unverified; triage out, don't accumulate |
| Superseded / completed docs | [docs/_archive/](docs/_archive/) |

Tiers adopted 2026-07-31 — [ADR-0001](docs/adr/0001-provenance-tiers.md). A decision
touching the security boundary, persistent data, public contracts, core architecture, or
cross-repo conventions gets an ADR; local implementation details never do.

## Quick reference

```bash
scripts/profile.sh <profile> up|down|attach|verify|audit
scripts/profile.sh <p> converge              # re-converge every agent's policy + skills
                                             # (build FIRST if the hook engine changed)
scripts/profile.sh list
scripts/profile.sh build --refresh-ai        # bump AI CLIs (tail layer only)
scripts/with-egress.sh <p> --with pypi -- '<cmd>'   # temporary egress widening
scripts/profile.sh <p> deps [--osv]           # dependency posture (host-side, read-only)
scripts/profile.sh <p> ollama enable|pull <model>|status   # local inference sibling (host-side ingest)
scripts/profile.sh <p> backend ollama|openrouter|anthropic [--model m] [--recreate]  # Claude Code endpoint switch
scripts/docker-gc.sh --dry-run               # host Docker hygiene (see above)
```

Host state: `~/.ai-sandbox/profiles/<profile>/`; workspace:
`~/repo/<profile>/` → `/workspace`. Rootless socket:
`/run/user/1000/docker.sock`. Container-side root is correct by design
(see ARCHITECTURE.md).

@AGENTS.local.md
