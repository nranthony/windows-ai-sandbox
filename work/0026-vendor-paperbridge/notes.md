# 0026 — notes: execution log

Everything below was run, not reasoned about. Where a number appears it came
from a command in this repo on the date given.

---

## 2026-09-09 — Phases A–F implemented, plus the build

Decisions (spec §5) were taken the same day; implementation followed in the
plan's order. Phase G stops at the build — see "Left for the owner".

### Phase A — re-vendor (P1–P3)

`just vendor-tools` mirrored three artifacts; `VENDORED.lock` went from 3 rows
to 5, the two new ones being `paperbridge.skill` and `paperbridge.wheel` at
0.2.1 / `9a12cd7628f6f61…`. Exactly what the handoff's §6.2 predicted, and
**vendor-tools.sh needed no change to do it** — the ADR-0014 generic-consumer
design held for a third artifact.

`member_pointer` gained a `paperbridge` arm and `.paperbridge-dir.local` was
created (gitignored, comment-tolerant header like the other two). Before:
`content: 2 verified against source, 1 HASH-ONLY`. After:

```
content: 3 verified against source, 0 hash-only
  content: paperbridge matches paperbridge@9a12cd76 (extracted, not hashed)
```

The wheel does match the source commit it claims — the check that only a
content diff can make.

**Gitignore decision, taken deliberately rather than by copying myclickup's
line.** `gh repo view` reports nranthony/paperbridge **PUBLIC**, so the
disclosure argument behind `sandbox_templates/skills/myclickup/` does not apply
and paperbridge's SKILL.md is TRACKED. The blanket `wheels/*.whl` ignore still
covers its wheel, for the different reason that `VENDORED.lock` is the committed
record. The asymmetry is now commented in `.gitignore` so it does not read as an
oversight and get "fixed".

### Phase B — the pin set (P4), and a hole that had to be closed with it

`uv export --frozen --all-extras --no-dev --no-emit-project --no-hashes
--no-annotate --no-header`, run against `pyproject.toml` + `uv.lock` extracted
at the **published** `source_commit` (not the member's HEAD, which is 3 commits
ahead) → **62 pins**, member tree left clean. Written to
`sandbox_templates/wheels-host/paperbridge-constraints.txt` with a header
carrying the regeneration command and a `# source_commit:` stamp.

**D2's mechanism was settled by measurement, not preference** (uv 0.12.5):
`uv tool install` **has** `-c/--constraints` and `-f/--find-links`, and has **no
`--require-hashes`** — which is what rules out a hash-bearing constraints file
and moves content verification onto the two host-built wheels instead.

**Not in the plan: `check_pins` in `vendor-tools.sh`.** Writing P4 exposed a gap
the plan itself created. The constraints file is derived from an upstream
payload by a route nothing else here watches, so re-vendoring without
regenerating it leaves **every existing check green** — wheel hash matches,
content diff matches — while the image would install the NEW wheel against the
OLD resolution. That is the "green summary printed over a check that never ran"
shape this repo has been burned by before, so it is now asserted:

- `--check` compares each `wheels-host/<artifact>-constraints.txt` stamp against
  the manifest's `source_commit` and **fails** on drift or on a missing stamp.
- `vendor` **warns** at the moment staleness is created but does not fail — the
  vendor succeeded, and reverting it would be the wrong repair.
- It keys off the file existing, not off an artifact name, so a second
  dependency-carrying artifact is covered the day its pins land. An artifact
  with no pin file is **counted and named**, never silently passed.

Mutation-checked live before committing to it: a corrupted stamp → exit 1 with
both commits quoted; a deleted stamp → exit 1; restored → exit 0.

### Phase C — egress (P5)

Five hosts added to `[citation-tools]`: `www.ncbi.nlm.nih.gov`,
`pmc.ncbi.nlm.nih.gov`, `www.arxiv.org`, `biorxiv.org`, `medrxiv.org`.
All **12 of 12** of the tool's `DOWNLOAD_HOSTS` are now present, no duplicates
anywhere in the file. The block header's "Every citation-client endpoint is
listed" was true of the API surface and false of the download surface; it now
says which, and records the direction rule and the measurement that found the
gap. `chemrxiv.org` remains the one deliberate asymmetry, in the safe direction.

### Phase D — secrets (P6)

`ZOTERO_API_KEY` / `ZOTERO_USER_ID` / `ZOTERO_GROUP_ID` / `MY_EMAIL` /
`NCBI_API_KEY` added to `secrets.env.template`, each cited to its
`validation_alias` in `src/paperbridge/_config.py` at the published commit, per
that file's own rule. `UNPAYWALL_EMAIL` is recorded as an accepted alias of
`MY_EMAIL` — the kind of plausible synonym that otherwise reads as unset. Also
recorded: paperbridge disables `.env` loading under `SANDBOX_PROFILE` (its
ADR-0003), so this file is the only route in.

### Phase E — the image (P7–P8)

**P7.** Both sdist-only packages built host-side, and the provenance was checked
before building rather than after: the sdist URLs and sha256s came from
paperbridge's own `uv.lock`, `sha256sum -c` passed on both downloads, then
`uv build --wheel`. Both are `py3-none-any`.

- `bibtexparser 1.4.4` — verified the built wheel carries the **v1** API
  (`load`/`loads`/`dump`/`dumps`, `bwriter.py`, `bibdatabase.py`), i.e. the
  version paperbridge's code actually needs and not 2.x.
- `sgmllib3k 1.0.0`

`SHA256SUMS` records **two** hashes each and says why they differ: the published
sdist hash is the provenance claim and is stable; the built wheel hash is what
the Dockerfile gates on and legitimately changes on rebuild.

**The install line was proven on the host before it was written into the
Dockerfile**, under `--no-build` to simulate Gate 3, into throwaway
`UV_TOOL_DIR`/`UV_TOOL_BIN_DIR`:

```
uv tool install --no-build -c <constraints> -f <wheels-host> \
  "paperbridge[docs,bibtex,zotero] @ file://<wheel>"
```

Resolved graph: **bibtexparser 1.4.4** (not 2.0.0), **pyzotero 1.11.0** (not
downgraded to 1.6.11), `whenever 0.9.5` present — which is the exact "quick
tell" the handoff's §7 names — `feedparser 6.0.12`, `sgmllib3k 1.0.0`. Then
`paperbridge --version` → `paperbridge 0.2.1`, matching the manifest, and
`paperbridge config` printed every setting as `set`/`unset`, never a value.

**P8.** One `RUN` handles both payloads. That is the fix for the trap recorded
in spec §4.5, not a tidy-up: the block must end by deleting `/tmp/wheels`
because the myclickup wheel is private and must not persist in a layer, so a
second `RUN` placed after it would find an empty directory, take the "no
vendored wheel — skipping" branch, and report success — a green build that
installed nothing. Keeping both installs in one layer makes that
unrepresentable.

The block refuses rather than guesses in five places. Every branch was exercised
by extracting the `RUN` body, joining its continuations, and running it under
`sh` with `uv` stubbed:

| Scenario | Result |
|---|---|
| no wheels at all | exit 0, skips (a clone without payloads still builds) |
| happy path | exit 0 |
| two paperbridge wheels | **exit 1**, refuses to guess |
| wheel present, constraints file missing | **exit 1**, refuses to install unpinned |
| host-built wheel hash mismatch | **exit 1** (`sha256sum -c`) |
| a pin absent from the installed graph | **exit 1**, "the constraints file did not take" |

`dockerfile-order.test.sh`: 8/8 — the chain's anchors each still appear exactly
once.

### Phase F — policy (P9–P10)

**P9.** 20/8/2 read out of `manifest.toml` and inserted into both templates by
script, never retyped. The agy half is the same set through the single
translation `Bash(x:*)` → `command(x)`, which is exactly the normalisation
`agent-policy.test.sh` applies in both directions.

- `just check-permissions`: paperbridge **0 MISSING** across allow/ask/deny.
- `agent-policy.test.sh`: 53/53, including "every claude {allow,ask,deny}
  command has an antigravity twin" and "antigravity adds nothing claude lacks".

Prefix analysis was **computed, not eyeballed**: no allow entry is a prefix of
any gated command, and no gated entry swallows an allowed read. Two pairs look
like collisions and are not — `zotero-tags` (allow) does not prefix
`zotero-tag-item` (ask), and `zotero-find` (allow) does not prefix
`zotero-file-item` (ask). Both are named in the deployed note so the next reader
does not have to re-derive them.

**P10.** Rule 23, `paperbridge-zotero-delete`, in the shared engine's **ask
tier**. Measured in both dialects with each agent's real envelope shape:

| Input | claude | agy |
|---|---|---|
| `paperbridge zotero-delete K1` | `permissionDecision:"ask"` | `decision:"force_ask"` |
| `echo hi; paperbridge zotero-delete K1` | ask | force_ask |
| `paperbridge --dry-run zotero-delete K1` | pass | allow |
| `paperbridge zotero-list` | pass | allow |
| `paperbridge zotero-update K1 …` | pass | allow |

`deny-destructive.test.sh`: **216/216** (was 207). Mutation-checked — replacing
the rule's `match` with `if false` turns exactly those 3 positive assertions
red and nothing else, so the suite measures the rule and not the fixture.

> One process note: the first agy check appeared to fail (`{"decision":"allow"}`)
> and it was the *test* that was wrong, not the rule — a claude-shaped envelope
> was passed with `--dialect=antigravity`, which the adapter cannot translate.
> agy's real shape is `{"toolCall":{"name":"run_command","args":{"CommandLine":…}}}`.
> Worth knowing before someone else "fixes" a rule that works.

### Docs (P14, partial)

`AGENTS.md` — suite counts corrected (207→216, 65→76), `wheels-host/` added to
the security-sensitive list with the reason it is load-bearing, and the three
new pin-half locks recorded beside the existing ones.
`ARCHITECTURE.md` — a "Vendored tools (with deps)" row and the repo map.
`sandbox_templates/skills/UPSTREAM.md` — paperbridge's vendored row, and why its
skill is tracked when myclickup's is not.

### Gate: `just test-offline`

Ten suites green after every edit above, then `check-upstreams` clean:

```
216 / 56 / 82 / 8 / 24 / 76 / 13 / 53 / 90
private-names: OK (121 files, 2 names)
VENDORED.lock matches the channel manifest (5 artifact rows)
content: 3 verified against source, 0 hash-only
pins: 1 artifact(s) pinned and current, 2 with no pin set (no runtime deps)
```

No `[SKIP]` lines — a skip would not have been a pass.

### Phase G — the build (P11), and what it proved

`scripts/profile.sh build` → exit 0, `windows-ai-sandbox:latest` at
`127ce261fcd1`, 3.59 GB (from 3.21). Only the tail rebuilt.

The build running at all is itself evidence: the whole block is under `set -eu`,
so the `sha256sum -c` on the two host-built wheels and the installed-graph
assertion both passed — either would have exited 1.

Verified against the built image (`docker run --rm --network none`, nothing
touched):

| Check | Result |
|---|---|
| `paperbridge --version` vs `VENDORED.lock` | `paperbridge 0.2.1` ✓ |
| the four pins that matter | `bibtexparser-1.4.4`, `pyzotero-1.11.0`, `sgmllib3k-1.0.0`, `feedparser-6.0.12` ✓ |
| bibtexparser **v1** API importable | `1.4.4`, `load`/`loads`/`dump`/`dumps` present ✓ |
| `config` never prints a key | every secret-bearing field `unset` ✓ |
| **`myclickup --version`** | `0.7.0` — the one-`RUN` change did not break it ✓ |
| `/tmp/wheels`, `/tmp/wheels-host` | both absent from the final layer ✓ |

That fifth row is the trap from spec §4.5, proven not to bite: had the two
installs been split across `RUN`s, paperbridge would have reported "no vendored
wheel — skipping" and the build would still have been green.

---

## Left for the owner

**Nothing above touched a running container.** Three profiles were up throughout
(`nranthony` 3 days, `therapod` 6 days, `fluidmomenta` 23 hours), and
`recreate` would drop them — including a VS Code attach.

1. **`scripts/profile.sh <p> recreate`**, per profile. The image is BUILT and
   verified (Phase G) — but the wheel reaches a container through the image, so
   the three running profiles are still on the old one. The policy templates
   converge on `up`; the CLI does not.
2. **Secrets.** Fill `ZOTERO_API_KEY` + one of the two ids, and `MY_EMAIL`, in
   each profile's `secrets.env`. Read at container **create**, so this and the
   recreate above are the same trip.
3. **The in-container spot-checks** (spec §6.4) — they need both of the above:
   `--version` against the manifest, `config` showing `set`/`unset`,
   a live `search`, a `download` against an allowed host, a `download` against
   an unlisted one returning the tool's own `blocked_host` rather than a
   connection error, and **a write prompting**. If any write executes without a
   prompt, that is a deployment defect, not a grant.
4. **`verify` then `audit`** on a recreated profile. Four security-sensitive
   files changed (Dockerfile, vendor-tools.sh, both policy templates, the
   allowlist), so tier 2 is the right level.
5. **Commit.** Nothing here is committed, and the branch in the working tree is
   `feat/0023-ollama-sibling` — unrelated to this item. Worth a branch of its
   own before committing.

## Owed back to paperbridge (spec §7)

Four of the handoff's five questions are answerable now; §7 has the wording.
The two rows to send verbatim:

```
paperbridge.skill 0.2.1 785779c72c4ae7ccc87929084681d315e2f6bdbf100f965e814b33e68e77a6a1 9a12cd7628f6f6182ce0339e68edf7ffd12788fc
paperbridge.wheel 0.2.1 ed448726a2215878c3a7221f54c227e4a0a7591f9b35aaadac35961b2b4406cd 9a12cd7628f6f6182ce0339e68edf7ffd12788fc
```

Plus three findings they cannot see from their side:

1. **`sgmllib3k 1.0.0` is a second host-built wheel**, which §4.2 does not name.
   It reaches `[zotero]` via `pyzotero 1.11.0 → feedparser 6.0.12`. Following
   §8 step 3 literally would still have failed Gate 3.
2. **`uv tool install` re-resolves and ignores their lock**, so §7's defect is
   an install-time refusal only under the pin. Unpinned it is worse: 2.0.0 has
   wheels, the build goes green, and BibTeX breaks at runtime.
3. **§2's forward-guard rationale does not match the shipped artifact** (spec
   §3). The command is `zotero-delete`, named that since `223c98c`; no bare
   `delete` ever existed, and `Bash(paperbridge delete:*)` does not prefix it.
   The change is a no-op for all three artifacts and needed no edit here. The
   same sentence is in `gen_allow.py`'s docstring, where it will be read as
   history.

And one cosmetic observation, offered rather than filed: `paperbridge config`
prints `None` for `zotero_user_id` / `zotero_group_id` where the secret-bearing
fields print `unset` — a raw Python repr reaching user-facing output. Not a
leak (an id is not a secret), just inconsistent with the line above it.

## A proposal for the channel

The constraints file is generated **here** from a member checkout, which means
this repo reaches into a member for a security-relevant input — a second
cross-repo pull of exactly the kind ADR-0014 closed for the wheel itself. The
better home is the channel: a `constraints` path in the artifact entry would put
the pin set through the one door alongside the artifact it pins, and let
`tools-check` hash it like everything else. Offered as a proposal, not a
requirement — `check_pins` makes the current arrangement safe, just not tidy.
