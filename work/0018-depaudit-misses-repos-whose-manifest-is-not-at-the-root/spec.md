# 0018 — `deps` silently skips any repo whose manifest is not at its root

**Status:** Draft. Root-caused and measured; the fix needs one design decision
(§4) before it is written.

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
