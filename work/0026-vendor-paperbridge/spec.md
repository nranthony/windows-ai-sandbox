# 0026 — Vendor paperbridge 0.2.1: the third channel artifact, and the first with dependencies

**Status: Accepted** — opened 2026-09-09 on receipt of
`depot/paperbridge/work/0001-channel-membership/handoff-windows-ai-sandbox.md`
(human-ferried; no container can reach this tree). **All five decision gates
closed the same day by the owner (§5); implementation not started.**

**Upstream item:** paperbridge `work/0001-channel-membership/` — proposal,
plan, notes, and the handoff. Its ADRs 0001–0005 carry the producer-side
rationale and are the reference for anything this spec states about the tool's
own behaviour.

**Channel state at opening:** `manifest.toml` `artifact.paperbridge` = **0.2.1**,
`kind = "wheel+skill"`, `source_commit 9a12cd7628f6f6182ce0339e68edf7ffd12788fc`.
`just verify` at the depot root reports `3 artifact(s) match the manifest`.

---

## 1. Why this is not a routine re-vendor

Two of this tier's working assumptions stop being true:

1. **A vendored tool has no runtime dependencies.** myclickup's zero-dependency
   invariant (its ADR-0002) is why the Dockerfile block could be verified with
   `--network none`. paperbridge depends on pydantic, pydantic-settings,
   requests, loguru, beautifulsoup4 and lxml before any extra is chosen.
2. **Every artifact's `proposed_deny` lists `delete` and `rm`.** The channel's
   `bin/gen_allow.py` now emits a forward guard only for a name the tool's
   parser does not define. See §3 — the change is real, its stated cause is not,
   and it requires nothing here.

The precedent for (1) already exists in this image and is the right one:
`weasyprint` sits in `/opt/uv/tools/weasyprint/` with thirteen third-party
packages, installed by `uv tool install` at `Dockerfile:193`. paperbridge is the
same mechanism. What is new is that the payload is **vendored**, so its
dependency resolution happens at image build under Gate 3, against floors this
repo did not write.

## 2. What was verified before opening this item

Measured 2026-09-09 in this tree, against the live channel. Recorded so it is
not re-measured, and so a later disagreement has something to diff.

| Claim | How checked | Result |
|---|---|---|
| Channel is internally consistent | `just verify` at depot root | 3 artifacts match |
| Permission counts | read from `manifest.toml`, never the handoff prose | 20 allow · 8 ask · 2 deny ✓ |
| `vendor-tools.sh` enumerates from the manifest | `just tools-check` | verified all 5 hashes incl. both paperbridge halves, **no code change needed** |
| A `wheel+skill` artifact is two lock rows | same run's drift diff | exactly `paperbridge.skill` + `paperbridge.wheel` ✓ |
| `--permissions` handles a third artifact | `just check-permissions` | clean section, 20/8/2 all MISSING (nothing deployed yet) ✓ |
| Nothing here asserts a fixed `proposed_deny` | read `do_permissions` | reads the manifest generically — **no edit required** |
| API egress hosts | exact-line grep of `proxy/allowed_domains.txt` | **13 of 13 already live** in `[citation-tools]` |
| Download egress hosts | same | **5 of 12 MISSING** — see §4.2 |
| `bibtexparser` has no wheel | paperbridge `uv.lock` @ 9a12cd762 — `sdist`, no `wheels` array | confirmed **offline** |
| `[docs]` is 100% wheels | same lock, per package | confirmed — pdfplumber, pymupdf, pymupdf4llm, trafilatura all ship wheels |
| weasyprint precedent | `Dockerfile:150-194` | real: `uv tool install`, `/opt/uv/tools`, thirteen deps |
| Channel no-ops (§5 of the handoff) | `git log` in depot on `bin/dirhash.py`, `manifest.toml` | dirhash untouched since first commit; myclickup/myconv rows byte-identical |

**The tree is red right now.** `just test-offline` ends on `check-upstreams`,
whose `tools-check` fails on the drift until step P1 lands. That is the
designed behaviour (AGENTS.md, "Boundary monitors") — clear it by re-vendoring,
never by muting.

## 3. The `gen_allow.py` forward-guard change — no-op here, and misattributed

The handoff §2 says the change was needed because paperbridge exposes an
ask-gated `delete` that the old unconditional guard would have shadowed:
the same string in `proposed_ask` and `proposed_deny`, deny winning, shipping an
ask rule that could never fire.

**That is not what the artifact contains.** The command is `zotero-delete`, and
it has been since the first CLI commit (`223c98c`, `src/paperbridge/cli/_parser.py`).
paperbridge defines neither `delete` nor `rm`, so both guards still emit —
`proposed_deny` in the shipped 0.2.1 manifest is `Bash(paperbridge delete:*)`
and `Bash(paperbridge rm:*)`, unchanged in shape from myclickup's. And
`Bash(paperbridge delete:*)` is not a prefix of `paperbridge zotero-delete`
under Claude Code's prefix matcher, so no collision was possible.

The change is therefore a **no-op for all three current artifacts**. It is
defensible as a forward guard against a future tool that *does* name a
subcommand `delete`; the causal story is retrospective. The same sentence sits
in `gen_allow.py`'s docstring, where it will be read as history.

**Action:** none in this repo. Report it back (§7) so the producer can correct
its own docstring and handoff — this ecosystem's standing rule is that prose
must not disagree with generated data, and this is that failure in miniature.

## 4. What this tier must actually do

### 4.1 Dependencies, Gate 3, and the resolution nobody pinned

**The image does not get the lock's graph.** `uv tool install <wheel>`
re-resolves from PyPI against the wheel's `>=` floors; paperbridge's `uv.lock`
is not consulted and cannot be. Three consequences, in descending nastiness:

1. **`bibtexparser>=1.4` resolves to 2.0.0 today**, which *has* wheels. Gate 3
   is satisfied, the build goes **green**, and every BibTeX feature breaks at
   runtime — the v1 API (`load`/`loads`/`dump`, `.bibdatabase`, `.bwriter`) was
   removed in 2.x. The handoff frames this as an install-time refusal (§4.2),
   which it is only under the lock's pin. **A green build is the failure mode
   here**, which is worse than the refusal it describes.
2. **`[zotero]` needs two host-built wheels today, not one.** The handoff names
   `bibtexparser` only. From the lock: `sgmllib3k 1.0.0` is also sdist-only and
   reaches `[zotero]` via `pyzotero 1.11.0 → feedparser 6.0.12 → sgmllib3k`.
   Following §8 step 3 literally still fails Gate 3.
3. **Pinning is ours to do.** Whatever is baked must name exact versions at
   install (a constraints file, or explicit `--with` pins), or the image's graph
   drifts from the tested one on every rebuild with no signal.

Gate 3 is **not** to be weakened. uv's `no-build-package` is a deny-list, so
"allow only this one" is inexpressible — the producer reached the same
conclusion in its ADR-0001 decision 4. Host-built wheels shipped beside the
paperbridge wheel is the route.

Also worth stating plainly: **the build bypasses Squid**, and the Python age
gate (`UV_EXCLUDE_NEWER`) is injected by `with-egress.sh` at *runtime only*. So
paperbridge's dependency tree enters the image under **no age gate at all**.
That is a new exposure class for a vendored payload, not a variation on an
existing one. It is an argument for pinning (which makes the graph reviewable),
not against vendoring.

### 4.2 Egress — five hosts short, in the direction that hurts

The tool carries its own download allowlist (`src/paperbridge/_hosts.py`,
its ADR-0002) and refuses an unlisted host *before* the request. Egress must be
**at least as wide**, or `download` believes a host is fetchable, tries, and
returns a connection error indistinguishable from a missing paper — the exact
confusion the tool's fence exists to prevent.

Measured against `proxy/allowed_domains.txt`:

| Host | Status |
|---|---|
| `www.ncbi.nlm.nih.gov` | **MISSING** |
| `pmc.ncbi.nlm.nih.gov` | **MISSING** |
| `www.arxiv.org` | **MISSING** |
| `biorxiv.org` | **MISSING** |
| `medrxiv.org` | **MISSING** |
| the other 7 download hosts | present |
| all 13 API hosts | present |

The wider direction is harmless: `chemrxiv.org` is live here and not on the
tool's list — the tool still refuses it. Only the narrow direction misleads.

These are apex/`www.` twins of hosts already allowed, so the addition is small.
Note the existing `[citation-tools]` block header claims "Every citation-client
endpoint is listed" — that was true of the API surface and is now false of the
download surface. Fix the sentence with the hosts.

### 4.3 Permissions — and the twin the handoff cannot see

`sandbox_templates/claude/claude-settings.json` takes the 20/8/2 from the
manifest. **`sandbox_templates/antigravity/antigravity-settings.json` must take
the identical set in agy grammar** (`command(paperbridge search)`, not
`Bash(paperbridge search:*)`). `scripts/agent-policy.test.sh` (53/53, offline)
diffs the two lists exactly, in both directions, for allow/ask/deny alike, with
no exception list — a one-sided edit fails before docker is involved, and
tier-1 `check_agent_policy_sync` reports the drift on every profile.

Two agy-specific facts drove D5, and D5 answered **`force_ask`**:

- **agy caches a plain `ask` as a permanent Always-Allow grant.** One approval
  of `zotero-delete` would make it permanent for that profile. Claude's `ask`
  re-prompts; agy's does not.
- The shared hook engine emits `force_ask` (agy's own enum, "always prompt,
  ignoring cached permissions") — but today only for the deletion verbs
  work/0004 taught it. The eight myclickup writes are already cache-backed and
  unfixed; without a rule, `zotero-delete` would join them.

So `zotero-delete` gets a hook rule rather than resting on the static `ask`
entry. Note what that buys on each side, because the engine is one and the
dialects are two: for agy it is the difference between "prompts every time" and
"prompts once, ever". For claude the ask tier is already re-prompting, and the
rule additionally means a headless or subagent invocation becomes a **deny
carrying the reason** rather than a silent classifier decision. Both are
improvements; only the agy one was the reason.

`zotero-delete` is the one that matters: the Zotero Web API's `DELETE` erases
rather than trashing (paperbridge ADR-0004, and its own reasoning flags that a
live test against a scratch group library would settle it beyond doubt). The
tool writes a JSON snapshot first and sends nothing if the snapshot fails — a
real fence, but a fence the sandbox does not own.

Separately: **`download` and `export` are on `proposed_allow` and write files to
disk unprompted.** Fenced rather than gated, by the producer's deliberate design
(its ADR-0005). That is an owner decision to take explicitly here, not to
inherit from a proposal — the channel proposes, this side disposes.

### 4.4 Secrets

`ZOTERO_API_KEY`, plus `ZOTERO_GROUP_ID` **or** `ZOTERO_USER_ID`, plus
`MY_EMAIL` (scholarly APIs rate-limit by contact address), optionally
`NCBI_API_KEY`. Into `sandbox_templates/common/secrets.env.template`, cited to
their call sites per that file's own standing rule — a plausible synonym reads
as unset.

`.env` reading is disabled under `SANDBOX_PROFILE` (paperbridge ADR-0003), so
the injected environment is the only route. `env_file` is read at container
**create**: rotation needs `recreate`, not `up`. Nothing tests this gap —
`webfetch.test.sh`'s "every env var is named in the template" lock is
broker-scoped.

### 4.5 The two mechanical traps

- **`member_pointer` has no `paperbridge` arm** (`scripts/vendor-tools.sh`), so
  the content half of `tools-check` degrades to `HASH-ONLY`. It says so out loud
  and counts it on the closing line, so this is partial coverage, not a silent
  pass — but it is half a check. One `case` line, plus
  `.paperbridge-dir.local` and its `.gitignore` entry beside the other two.
- **`Dockerfile:701` ends the myclickup block with `rm -rf /tmp/wheels`.** A
  second `RUN` added after it finds an empty directory, takes the *"no vendored
  wheel — skipping"* branch, and reports success. **Green build, nothing
  installed.** Handle both wheels in one `RUN`, or move the cleanup to the last
  block. Keep the per-artifact "two wheels is a refusal" count.

## 5. Decisions — taken 2026-09-09 (owner)

All five gates closed at opening. Recorded here as the authority; the plan's
phases are written against them.

| # | Decision | Consequence |
|---|---|---|
| **D1** | **Bake all extras** — `[docs,bibtex,zotero]` | Both sdist-only packages are in scope: `bibtexparser==1.4.4` **and** `sgmllib3k==1.0.0` need host-built wheels (§4.1) |
| **D2** | **Pin via a generated constraints file** — see §5.1 | The image's graph is exactly paperbridge's locked graph, and a rebuild cannot re-resolve it |
| **D3** | **Add the 5 missing download hosts** | Egress becomes ≥ the tool's own list; a refusal reads as `blocked_host`, not a connection error |
| **D4** | **Deploy the manifest's 20/8/2 as proposed** | 20 reads (incl. `download`/`export`) in `allow`; all 8 Zotero writes in `ask`; `delete`/`rm` forward guards in `deny` |
| **D5** | **`force_ask` for `zotero-delete`** | A shared-hook rule, not a static list entry — reason: agy caches a plain `ask` as a permanent Always-Allow grant, and the owner rates that agent unreliable enough that one approval must not be permanent |

### 5.1 D2 — the pin mechanism, measured

Best practice was not obvious, so it was settled against the real tool rather
than by principle. Verified on `uv 0.12.5` (the host's; the image installs uv in
the Gate 3 block):

- `uv tool install` **has** `-c/--constraints` and `-f/--find-links`.
- `uv tool install` has **no** `--require-hashes`. So a hash-bearing constraints
  file buys nothing here, and content verification has to come from somewhere
  else (see below).
- `uv export --frozen --all-extras --no-dev --no-emit-project --no-hashes
  --no-annotate --format requirements-txt` run in the member produces a clean
  **62-package `==` pin set** and leaves the member tree untouched. Confirmed by
  running it: exit 0, `git status --porcelain` empty.

**The install form:**

```
uv tool install \
    -c   <constraints.txt> \
    -f   <host-built-wheels-dir> \
    <paperbridge wheel>
```

Constraints pin every version to the locked one while `--find-links` supplies
the two wheels PyPI does not publish. Gate 3's `no-build = true` stays untouched
— nothing is built at image-build time, which is the whole point.

**Why constraints rather than the alternatives.** `--with` pins restate the
graph by hand and drift from it silently. Installing the exported requirements
file directly would install paperbridge's deps *instead of* resolving from the
wheel's own metadata, so a future wheel adding a dependency would be missed
rather than resolved. Constraints keep the wheel authoritative about *what* it
needs and this repo authoritative about *which version* it gets.

**Hashes: where verification actually happens.** Since `--require-hashes` does
not exist on this subcommand, the two host-built wheels are hash-gated the way
every other payload in this repo is — their sha256 recorded here and checked in
the Dockerfile **before** the install runs. That mirrors `vendor-tools.sh`'s own
rule (verify everything before anything moves) rather than inventing a second
pattern. The remaining 60 packages come from PyPI over TLS at their pinned
versions; that is the same trust the rest of the image's Python already rests on.

**The residual, stated rather than hidden.** The constraints file is derived
from the **member checkout's** `uv.lock`, not from the channel — a second
cross-repo pull of exactly the kind ADR-0014 exists to close. Two mitigations
and one ask:

- Generate it at the **published `source_commit`**, never the member's HEAD —
  same rule `content_check` already follows, and for the same reason (a member
  ahead of the channel is ordinary, not drift). `git show <commit>:uv.lock` and
  `:pyproject.toml` into a temp dir, then export there.
- Regeneration is triggered by re-vendoring: a republish moves `source_commit`,
  which `tools-check` already catches. A re-lock with no version bump still
  moves the commit, so it is caught too.
- **The right long-term fix is producer-side**: the channel should publish the
  export beside the wheel, so the pin set arrives through the one door with the
  artifact it pins. Raised in §7.

## 6. Definition of done

1. `just tools-check` green, content half **not** `HASH-ONLY`.
2. `just test-offline` green — all ten suites, then `check-upstreams`.
3. `scripts/profile.sh <p> verify` green; `audit` run (this touches the
   Dockerfile, `vendor-tools.sh`, both policy templates and the allowlist —
   four entries on the security-sensitive list).
4. In a rebuilt, recreated container:
   - `paperbridge --version` prints `paperbridge 0.2.1` and matches the manifest;
   - `paperbridge config` shows each setting `set`/`unset` and **never prints a
     key** (if it does, that is a defect to report upstream, not a convenience);
   - `paperbridge search "heart rate variability" --limit 3` returns results;
   - a `download` against an allowed host succeeds; one against an unlisted host
     returns the tool's own `blocked_host`, not a connection error;
   - **a write prompts.** If any write executes unprompted, that is a deployment
     defect, not a grant.
5. Commit messages state the security impact; `ARCHITECTURE.md` and
   `sandbox-hardening-package.md` updated; `sandbox_templates/skills/UPSTREAM.md`
   gains its vendored-skill row.

## 7. What is owed back to paperbridge

The handoff's §9 asks five questions. Four are answered by the decisions; the
first needs P1 to land:

1. The two `VENDORED.lock` rows — **pending P1.**
2. Which of the 8 `ask` entries were granted, and in which tier. **All eight, as
   proposed, in `ask`** — plus `zotero-delete` additionally carries a shared-hook
   `force_ask` rule, so under agy it prompts every time rather than once (D5).
3. Whether egress matches the tool's download list. **Yes, after P5** — the five
   apex/`www.` twins that were missing get added, so egress is a superset. The
   one difference is harmless-direction: `chemrxiv.org` is allowed here and is
   not on the tool's list, so the tool still refuses it.
4. Whether the `bibtexparser` wheel was built, at what version. **Yes,
   `==1.4.4`** — **and `sgmllib3k==1.0.0` is a second one they did not name**
   (§4.1), reached via `pyzotero 1.11.0 → feedparser 6.0.12`.
5. Whether §2's forward-guard change required an edit here. **No** — and its
   stated cause does not match the shipped artifact (§3). Worth correcting in
   `gen_allow.py`'s docstring and the handoff.

Plus two they did not ask:

- **`uv tool install` re-resolves and ignores their lock** (§4.1). Their §7
  re-lock still matters for their own tests, but it does not by itself decide
  what this image gets. This side pins from a constraints file generated at the
  published `source_commit`.
- **The channel should publish that export beside the wheel.** Generating it
  here means this repo reaches into a member checkout for a security-relevant
  input — a second cross-repo pull of exactly the kind ADR-0014 closed for the
  wheel itself. A `constraints` path in the manifest entry would put the pin set
  through the one door with the artifact it pins, and would let `tools-check`
  hash it like everything else. Offered as a proposal, not a requirement: this
  side is unblocked either way (§5.1).

## 8. Out of scope

- The producer's re-lock (`bibtexparser<2`, `feedparser>=6.0.14`). Theirs to
  land; it does not change the wheel vendored here, and a follow-up is promised.
- Bringing paperbridge to a profile's workspace `.venv` as a library. Different
  question, different mechanism (`with-egress.sh --with pypi`), and the
  state-placement table already answers it.
- Wiring the eight *myclickup* writes through `force_ask` (work/0004 Future
  scope 1). D5 may make the case stronger; it does not fold into this item.
