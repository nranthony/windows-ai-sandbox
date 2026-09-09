# 0026 — plan: ordered host-side steps

Sequenced against [spec.md](spec.md). **All five decisions are closed** (spec
§5), so every phase below is executable. P1–P3 clear the currently-red
`test-offline` and are independent of the rest.

Decisions in force: bake **all** extras · pin via a **generated constraints
file** · **add** the 5 download hosts · deploy the manifest's **20/8/2** as
proposed · **`force_ask`** for `zotero-delete`.

Every step here is host-side and human. No container can reach this tree, and
nothing below may be attempted from inside one.

---

## Phase A — clear the drift (no decisions needed)

**P1. Re-vendor.**

```
just vendor-tools --dry-run     # read the plan before it copies
just vendor-tools
```

Expect: 5 verified hashes, 3 mirrored artifacts, `VENDORED.lock` gaining
`paperbridge.skill` and `paperbridge.wheel` at 0.2.1 / `9a12cd7628f6f61…`.
The wheel lands in `sandbox_templates/wheels/`, the skill at
`sandbox_templates/skills/paperbridge/SKILL.md`.

`.gitignore` already covers `sandbox_templates/wheels/*.whl`. **Check whether
`sandbox_templates/skills/paperbridge/` should be gitignored** the way
`skills/myclickup/` is — that entry exists because myclickup is private. If
paperbridge is public (MIT, public README), the skill can be tracked; decide
deliberately rather than by copying the myclickup line.

**P2. Teach the content check about the member.**

- `scripts/vendor-tools.sh`, `member_pointer()`: add
  `paperbridge) printf 'PAPERBRIDGE_DIR .paperbridge-dir.local' ;;`
- create `.paperbridge-dir.local` with a comment header matching the other two
  pointers (the parser is comment-tolerant *because* reading a comment as the
  path is a bug already shipped once here)
- add `.paperbridge-dir.local` to `.gitignore` beside the other two

Then `just tools-check` must report `content: 3 verified against source, 0
hash-only`. If it still says `HASH-ONLY`, the pointer is wrong — a broken
pointer is a hard FAIL by design, so an absent one is the state to avoid.

**P3. Confirm green.**

```
just test-offline      # ten suites, then check-upstreams
```

`vendor-tools.test.sh` should pass untouched — its fixture is self-contained and
does not read the live channel. If it fails, something in P2 changed parsing.

---

## Phase B — generate the pin set (D2)

**P4. Produce the constraints file**, at the **published `source_commit`**, not
the member's HEAD:

```
# in a temp dir, from the member checkout
git -C <member> show 9a12cd762:pyproject.toml > pyproject.toml
git -C <member> show 9a12cd762:uv.lock       > uv.lock
uv export --frozen --all-extras --no-dev \
          --no-emit-project --no-hashes --no-annotate \
          --format requirements-txt \
  > <repo>/sandbox_templates/wheels-host/paperbridge-constraints.txt
```

Verified 2026-09-09 against the member checkout: exit 0, **62 packages**,
member tree left clean. `--no-emit-project` drops the `-e .` line, which a
constraints file must not contain; `--no-hashes` because `uv tool install` has
no `--require-hashes` and two of the pins will be satisfied by host-built wheels
whose hashes PyPI never published (spec §5.1).

Commit the file — it is the reviewable record of what the image resolves to, and
a version moving shows up as a one-line diff. Header comment must name the
`source_commit` it was generated at and the exact command, so regenerating is
mechanical rather than remembered.

Confirm the two sdist-only pins are present and correct before moving on:
`bibtexparser==1.4.4`, `sgmllib3k==1.0.0`.

---

## Phase C — egress (D3: add)

**P5.** Add to the `[citation-tools]` block in `proxy/allowed_domains.txt`:

```
www.ncbi.nlm.nih.gov
pmc.ncbi.nlm.nih.gov
www.arxiv.org
biorxiv.org
medrxiv.org
```

Under a comment naming `paperbridge`'s `src/paperbridge/_hosts.py` as the source
of truth and the direction rule (egress must be ≥ the tool's list; narrower
turns a clean `blocked_host` into a connection error). Correct the block
header's "Every citation-client endpoint is listed" — it is true of the API
surface, not the download surface.

Do **not** add a `.arxiv.org` / `.biorxiv.org` wildcard. The tool spells out
apex and `www.` forms deliberately (its ADR-0002: a suffix rule allowing
`*.arxiv.org` also allows `arxiv.org.example.net`); this list should match that
discipline.

`proxy/` is a directory mount, so the edit is live to a running proxy —
`squid -k reconfigure` picks it up, no recreate. Verify with the dashboard's
allowlist view **via git diff**, not by trusting a save (the dashboard rewrites
this file wholesale).

---

## Phase D — secrets (no decision needed beyond D1)

**P6.** Add a `paperbridge` block to
`sandbox_templates/common/secrets.env.template`:

- `ZOTERO_API_KEY` — required for every `zotero-*` command
- `ZOTERO_GROUP_ID` **or** `ZOTERO_USER_ID` — group takes precedence if both set
- `MY_EMAIL` — CrossRef polite pool and Unpaywall (Unpaywall requires it)
- `NCBI_API_KEY` — optional; raises PubMed from 3 to 10 req/s

Cite each to its call site in `src/paperbridge/_config.py`, per the template's
own rule. State the create-time rule (`recreate`, not `up`) and that `.env`
reading is disabled under `SANDBOX_PROFILE` so this file is the only route.

---

## Phase E — the image (D1: all extras, D2: constraints)

**P7. Build the two host-side wheels.** Both are required, because D1 bakes
`[bibtex]` and `[zotero]`:

- `bibtexparser==1.4.4` — **pin the version explicitly.** `pip wheel
  bibtexparser` resolves 2.0.0 today, which removed the v1 API this code uses.
- `sgmllib3k==1.0.0` — reached via `pyzotero 1.11.0 → feedparser 6.0.12`; the
  handoff does not name it. Needed unless the producer's `feedparser>=6.0.14`
  re-lock lands first, which it has not.

Home: **`sandbox_templates/wheels-host/`**, a sibling of `wheels/`. Not
`wheels/` itself — `vendor-tools.sh` rotates `<art>-*.whl` there and the
Dockerfile counts them to refuse ambiguity; a non-channel wheel sitting in that
directory would be a payload the channel does not know about, inside the count
that exists to catch exactly that. `.gitignore` and the `COPY` must agree, and
this directory needs its own `.gitkeep` for the same reason `wheels/` has one (a
`COPY` of a directory absent from a fresh clone is a hard build failure).

**Record each wheel's sha256** in the repo alongside them. Since `uv tool
install` has no `--require-hashes` (spec §5.1), this is where content
verification lives: the Dockerfile checks both hashes **before** the install
runs, mirroring `vendor-tools.sh`'s own rule that nothing is used until
everything verifies.

**P8. The Dockerfile block.** Below the myclickup block — the tail, so a payload
bump does not re-run the AI-CLI install or either gate.

Four things to get right:

1. **`rm -rf /tmp/wheels` currently ends the myclickup `RUN` (`Dockerfile:701`).**
   A new `RUN` after it sees an empty directory and takes the "no vendored
   wheel — skipping" branch: green build, nothing installed. Either handle both
   payloads in one `RUN`, or move the cleanup to the last block that needs it.
2. **Per-artifact refusal count.** Mirror myclickup's "two wheels is a REFUSAL,
   not a pick-one" for `paperbridge-*.whl`, with its own message.
3. **Hash-gate the two host-built wheels** before installing (P7).
4. **The install form** (spec §5.1), all extras, pinned:

   ```
   uv tool install \
       -c /tmp/wheels-host/paperbridge-constraints.txt \
       -f /tmp/wheels-host \
       "/tmp/wheels/paperbridge-<ver>-py3-none-any.whl[docs,bibtex,zotero]"
   ```

   Then **verify the graph, not just the exit code**: assert
   `bibtexparser==1.4.4` and `pyzotero==1.11.0` are what actually landed. A
   green `uv tool install` is the failure mode this whole phase exists to
   prevent (spec §4.1) — the exit code cannot see it.

Then `bash scripts/dockerfile-order.test.sh` (8/8). The chain's anchors must
each still appear exactly once — do not copy the myclickup comment header, it
will duplicate an anchor and redden the suite. Consider adding the paperbridge
block to the ordered chain: `min-release-age` does not apply to a `-c`-pinned
install, but the block must stay **below** both gates, and an anchor is how that
gets enforced rather than remembered.

---

## Phase F — policy (D4: as proposed, D5: force_ask)

**P9. Both templates, in one commit.** They are diffed exactly in both
directions by `scripts/agent-policy.test.sh`, so a one-sided edit fails offline.

- `sandbox_templates/claude/claude-settings.json` — the 20/8/2 from the
  manifest, in `Bash(paperbridge <cmd>:*)` grammar
- `sandbox_templates/antigravity/antigravity-settings.json` — the identical set
  in `command(paperbridge <cmd>)` grammar

Read the entries out of `manifest.toml`; **do not retype them from the handoff
or from this plan.** Transcription across a repo boundary is the failure that
put a wrong allow-list count in three documents for two days.

Write the `_paperbridge_note` in the style of `_myclickup_note`: the surface as
of 0.2.1 (27 commands — 17 reads, 2 fenced reads, 8 writes), what was promoted
and by whose sign-off, and the prefix analysis. On that last point, one pair
needs stating because it looks like a collision and is not: allow
`Bash(paperbridge zotero-tags:*)` does **not** match `paperbridge zotero-tag-item`
(the ask entry) — `zotero-tag-item` does not start with `zotero-tags`. Verify
with `just check-permissions` rather than by eye; it reports prefix over-matches
by name.

**P10. The `force_ask` rule for `zotero-delete` (D5).** Add it to the shared
engine under `sandbox_templates/claude/hooks/`, in the **ask tier** — the
engine's three tiers are warn / ask / deny, and the ask tier is dialect-branched
precisely for this: claude emits `permissionDecision:"ask"`, agy emits
`decision:"force_ask"`. That branch is the whole reason D5 is expressible; do
not add a fourth tier or a dialect-neutral form.

The static `ask` entries from P9 stay. They are not redundant: for claude the
`ask` list is what re-prompts in an interactive session, and the hook is what
makes a headless or subagent invocation a deny-carrying-the-reason. For agy the
static entry is the cache-backed grant and the hook is what overrides it. Either
one alone leaves a hole, in opposite directions.

Extend `deny-destructive.test.sh` (currently 207/207) with cases in **both**
dialects, including the unknown-dialect assertion — one engine, two agents, and
the failure postures are deliberately opposite (claude fails open, agy fails
closed).

Then: `bash scripts/agent-policy.test.sh` (53/53) and
`bash scripts/deny-destructive.test.sh`.

---

## Phase G — deploy and prove

**P11.**

```
scripts/profile.sh build
scripts/profile.sh <p> recreate      # not `up` — env_file is read at create
```

**P12. Spot-check in the container** (spec §6.4). The last one is the one that
matters: **if any write executes without a prompt, that is a deployment defect,
not a grant.**

**P13. Verify and audit.**

```
scripts/profile.sh <p> verify        # tier 1
scripts/profile.sh <p> audit         # tier 2 — four security-sensitive files touched
bash scripts/private-names-check.sh
```

**P14. Docs.** `ARCHITECTURE.md`, `sandbox-hardening-package.md`,
`sandbox_templates/skills/UPSTREAM.md` (paperbridge's vendored-skill row).
Commit messages state the security impact.

**P15. Hand back** the five answers in spec §7, plus the two findings the
producer cannot see: `sgmllib3k` as a second host-built wheel, and that
`uv tool install` re-resolves and ignores their lock. Route it to
`depot/inbox/` (the doorbell) with the tracked original here.

---

## Rollback

P1–P2 are `git revert` plus re-running `just vendor-tools` against the previous
manifest — but note the channel has already moved, so a revert of the lock
without a matching channel state re-reds `tools-check`. P7–P8 are an image
rebuild. P9 is a template revert plus `scripts/profile.sh <p> converge` on every
profile; a converge under a running claude session is a lost-update race in both
directions, so stop the session first.
