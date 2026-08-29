# 0018 — `deps` silently skips any repo whose manifest is not at its root

**Status: IMPLEMENTED 2026-08-28** — §4 decided **B + C**, both shipped, with a
third finding (§7) fixed alongside. `my_comfyui` now appears in the report, and
so do four other repos nobody knew were missing.

**Touches:** `scripts/profile.sh` (the `deps` enumerator) and possibly
`scripts/depaudit.py`. Not a security boundary file, but it is a **detector**,
and a detector that under-reports is the failure mode AGENTS.md already calls
out for `with-egress.sh`: it "silently *under-reports* — which reads exactly
like a clean run."

**Found 2026-08-28** while risk-scanning ComfyUI's dependencies for work/0016.
Unrelated to ComfyUI except that ComfyUI is what exposed it.

---

## 1. The symptom

`scripts/profile.sh nranthony deps --osv` prints a closing summary of **11
repos**. `my_comfyui` is not among them, and nothing says so:

```
  nranthony/biohub-kaggle-2026      FAIL 0 WARN 3 ...
  ... 11 rows ...
```

The report reads as complete workspace coverage. It is not. The omitted repo is
the one with the largest and least-scrutinised dependency surface in the
workspace — **70 resolved packages**, five of which need an age-gate bypass to
install at all.

## 2. Root cause — a depth-1 manifest predicate

`scripts/profile.sh:1706-1714` builds the scan list:

```bash
for m in package.json pyproject.toml requirements.txt Pipfile; do
  [[ -e "$ws/$m" ]] && { dep_roots="$ws"; break; }
done
for d in "$ws"/*/; do                      # immediate children only
  for m in package.json pyproject.toml requirements.txt Pipfile; do
    [[ -e "$d$m" ]] && { dep_roots="$dep_roots ${d%/}"; break; }
  done
done
```

A child repo qualifies only if a manifest sits at **its** root. `my_comfyui`
keeps its manifest at `comfyui/requirements.txt` — depth 2 — because `comfyui/`
is the upstream checkout, gitignored, with the repo's own files above it. So it
never enters `dep_roots` and is never passed to depaudit.

`depaudit.py` itself is **root-scoped by design** and that is correct: `discover()`
(`:214`) probes `root / "<lockfile>"` and `root.glob("requirements*.txt")`,
deliberately non-recursive, so a repo is never marked FAIL for a toolchain it
does not use. The defect is in the **caller's enumeration**, not in depaudit's
scoping. Fixing it in depaudit would push recursion into every check that
currently assumes one root.

The irony is that the comment two lines above the loop already names this exact
failure — "Without this the common case reports 'no manifests' and reads as
clean" — and the fix it introduced stops one level short of its own reasoning.

## 3. Why it is worse than a missing row

The enumerator warns only when it finds **nothing**:

```bash
[[ -n "${dep_roots// /}" ]] || { warn "No manifests found under $ws"; exit 0; }
```

Total failure is loud. **Partial** coverage is silent — the summary prints the
repos it did scan and says nothing about the ones it did not consider. That
inverts the rule this repo states for its boundary monitors: *"A skip is not a
pass. The aggregate recipes say so on their closing line rather than claiming
full coverage, because the failure that started this was a green summary printed
over a check that never ran."* That principle is implemented for
`check-upstreams` and absent here.

Concretely, for the whole life of the `deps` subcommand, this workspace's
ComfyUI tree has never appeared in a posture report, and no run said so.

## 4. DECISION — how deep, and what to exclude

Recursion is not free. Two measured constraints:

**a. `skipped()` already exists and must be used.** `depaudit.py:309` documents
why a literal name list is insufficient: a real workspace surfaced
`pip install babel` out of `pipeline/.venv-linux/.../jupyter_server/i18n/README.md`
— a third party's docs reported as the user's own. Any recursive discovery
inherits that trap; `.venv-linux`, `.venv311`, `env`, `site-packages` and
`node_modules` all carry manifests belonging to other projects.

**b. ComfyUI's custom nodes ship their own manifests.** Measured under
`my_comfyui` today: three `requirements*.txt` at depths 2, 3 and 4, one of them
inside `custom_nodes/`. That is small now and grows with every node installed —
and a custom node's requirements are NOT the repo's declared dependencies. Naive
`rglob` turns one omitted repo into dozens of spurious ones.

Options:

| | Approach | Cost |
|---|---|---|
| **A** | Bounded depth (2 or 3) + `skipped()` | Simple; still guesses at depth |
| **B** | Depth-1 as now, but scan a child's subdirs only when the child has NO root manifest | Targets exactly this case; no change for well-shaped repos |
| **C** | Report-only: keep discovery as-is, but LIST every child repo that was considered and skipped, with the reason | Cheapest; fixes the silence, not the coverage |

**C is not an alternative to A/B — it is the half that must ship regardless.**
The coverage gap is a bug; the silence is what made it invisible for months. Even
with perfect discovery, a repo that is skipped for any reason (no manifest at
all, unreadable, symlinked) should appear on the closing line.

Recommendation: **B + C**. B is precisely scoped to the observed shape — a repo
whose real manifest lives one level down inside a vendored upstream checkout —
and cannot change behaviour for any repo that already scans correctly. C makes
the next gap of this kind announce itself.

## 5. Steps

1. Decide §4.
2. Implement in `scripts/profile.sh`'s `deps` enumerator. `depaudit.py` stays
   root-scoped; if a shared skip predicate is wanted host-side, expose
   depaudit's rather than writing a second one that can drift.
3. Closing line reports scanned AND skipped counts, never scanned alone.
4. Extend `scripts/depaudit.test.sh` (43/43): a fixture repo whose only manifest
   is at depth 2 must be scanned, and a `.venv`/`site-packages`/`custom_nodes`
   manifest must NOT be. Both directions, since the failure modes are opposite —
   miss a real repo, or invent a dozen fake ones.
5. Re-run `deps --osv` and confirm `my_comfyui` appears.

## 6. Not in scope

- **The ComfyUI dependency risk itself.** Already assessed 2026-08-28 against
  the 70-package resolved set: zero OSV advisories; every pinned version has a
  wheel so Gate 3 needs no exception; the five age-gate bypasses are a single
  upstream release (`comfyui-workflow-templates` 0.11.48 pins its four siblings
  exactly, all published within 29 seconds); `comfy-aimdo` and `comfy-angle`
  carry PEP 740 attestations binding them to `Comfy-Org/*` via Trusted
  Publishing. Recorded here so the next person does not redo it — but it is a
  point-in-time result, which is the argument for the detector working.
- **Custom-node dependencies.** A custom node's `requirements.txt` is a real
  supply-chain surface but a different question, and answering it needs a
  decision about whether the sandbox treats installed nodes as the user's
  dependencies or as third-party vendored code. See work/0016 §7.

---

## 7. A second silence, found while fixing the first

Repairing the enumeration would have surfaced `my_comfyui/comfyui` and then
reported this:

```
**Checked:** 5 package(s)
```

Its `requirements.txt` carries **35** requirement lines. `enumerate_locked`
matches only `([A-Za-z0-9._-]+)\s*==\s*([^\s;]+)`, because OSV is queried by
name AND version and only `==` supplies one — so `torch`, `torchsde`,
`torchvision` and 27 others are dropped without a word. "Checked 5 package(s)"
is a **true sentence that reads as coverage of the file**, which is the same
defect as §3 one level down: not a wrong answer, an unstated scope.

Fixed by reporting, not by resolving. Resolving a range means building an
environment to enumerate it — the act this tool exists to avoid (`depaudit.py`
header, D1). Naming what was not checked costs nothing and is honest.

## 8. What shipped (2026-08-28)

**`scripts/depaudit.py`**

- `enumerate_roots(ws, max_depth=2)` → `(verdict, path, reason)` per repo, where
  verdict is SCAN **or SKIP** and both are returned. Depth is bounded AND
  conditional: a repo's subdirs are examined only when its own root has no
  manifest, and `_descend` stops at the FIRST level that carries one — otherwise
  finding `<repo>/comfyui` would go on to collect
  `comfyui/tests-unit/requirements.txt`, which is that checkout's own test
  fixture, not the repo's declared dependencies. This cannot change the result
  for any repo that already scanned correctly.
- `_tree_skipped()` **composes** `skipped()` rather than re-implementing it, and
  adds only `PLUGIN_DIRS` (`custom_nodes`, `extensions`, `plugins`). Two
  predicates that must agree will drift — this repo has paid for that twice with
  its two hand-edited policy lists. `custom_nodes` deliberately did NOT go into
  `skipped()` itself: that would also stop `_child_rc_files` from noticing an
  `.npmrc` a node drops, which is a real detection this has no reason to lose.
- `roots` subcommand (offline, tsv or json) so the enumeration is callable and
  testable on its own.
- `unpinned_requirements()` plus reporting in `deps` (§7), in md and json alike,
  and in the "no lockfile-pinned packages found" early exit — the path where an
  all-unpinned file would otherwise have exited 0 in silence.

**`scripts/profile.sh`** — the depth-1 loop replaced by a `depaudit roots` call.
The enumeration moved rather than being patched in place for two reasons: the
exclusion predicate is now depaudit's own, and bash in `profile.sh` has no test
suite while `depaudit.test.sh` does. The summary now closes with
`scanned N repo root(s), skipped M.` and lists every skipped repo with its
reason under `NOT SCANNED — a skip is not a pass`.

**`scripts/depaudit.test.sh`** — 43 → **56** offline. Ten assertions on
enumeration, three on unpinned lines. The enumeration ones lock **both**
directions, because the failure modes are opposite: a manifest one level down
must be SCANNED, and a manifest under `venv/`, `.venv/`, `site-packages/` or
`custom_nodes/` must NOT be. Two more lock the C half — every child appears as
SCAN or SKIP, and an out-of-bounds depth is reported rather than dropped.
Mutation-checked: `--max-depth 1` turns the deep-repo assertion red, so it is
measuring the fix and not the fixture.

### Measured, after the change

`scripts/profile.sh nranthony deps` — **16 repo roots scanned, 9 skipped and
named**, against 11 before. `my_comfyui/comfyui` is there, and so are four
others that were equally invisible: `biogentic/Biomni`, `depot/myclickup`,
`depot/paperbridge`, `protein_models/alphafold`. The four are the same shape —
a repo one level inside a container directory — and none of them had ever been
scanned either. Nothing said so, which is §3 in one line.

`depaudit deps my_comfyui/comfyui` now prints `Checked: 5` beside
`Not checked: 30 requirement line(s) with no ==pin`.

`just test-offline`: ten suites green (207 / 56 / 82 / 8 / 24 / 65 / 13 / 53 / 90),
then `check-upstreams` clean.

### Deliberately not done

- **Resolving unpinned requirements** (§7): out of scope by design constraint.
- **Custom-node dependencies** (§6): still excluded, still a real surface, still
  a different question. The exclusion is now explicit and tested rather than
  incidental.
- **A `--max-depth` flag on `profile.sh deps`.** The default is the measured
  shape; a knob invites someone to widen it past what the skip predicate can
  keep honest.
