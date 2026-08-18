# 0006 — the manifest keys the consumer silently drops

**Status:** Not started. **RE-INVESTIGATE BEFORE IMPLEMENTING** — see §3. Raised
2026-08-17 from a `just tools-check` diagnosis; the finding is incidental to that
drift, not its cause.

**Exit rule:** delete this folder, or move to [`docs/_archive/`](../../docs/_archive/),
when the work merges.

**Security-sensitive.** Touches `scripts/vendor-tools.sh`, which is on the
security-sensitive list in [AGENTS.md](../../AGENTS.md): it is the one door every
vendored payload enters through. Any change here needs a SECURITY IMPACT line in
the commit, `bash scripts/vendor-tools.test.sh` green (currently 57/57), and
`scripts/profile.sh <p> verify`. Run `just test-offline` before calling it done.

---

## 1. Origin

While diagnosing a real `tools-check` failure (myconv 0.3.0 → 0.4.0, legitimate
upstream drift, cleared by re-vendoring) the channel manifest was read closely and
one entry turned out to carry a key the consumer never sees:

```toml
[artifact.myconv]
kind = "plugin"
version = "0.4.0"
...
asserts = { myclickup = ">=0.3.0" }     # <- consumed by nobody on this side
```

Nothing was wrong with that drift, and nothing is wrong with the image today. The
finding is about what the consumer *cannot* see, which by construction produces no
symptom.

## 2. The finding

### 2.1 What actually happens

`manifest_flat` (in `scripts/vendor-tools.sh`, the single manifest extraction
point) walks each artifact table and emits `artifact<TAB>key<TAB>value` lines:

```python
if isinstance(val, (str, int)):
    print(f"{name}\t{key}\t{val}")
elif isinstance(val, list):
    for item in val:
        print(f"{name}\t{key}[]\t{item}")
```

TOML values that are neither scalar nor list fall off the end of that `if/elif`
with no `else`. A dict — a TOML inline table — is dropped without a word. Measured
against the live manifest on 2026-08-17, exactly one key is affected:

```
DROPPED  myconv  asserts = {'myclickup': '>=0.3.0'}  (type dict)
```

Three adjacent type gaps are in the same expression and should be settled in the
same pass rather than found one at a time later:

| TOML shape | Python type | What `manifest_flat` does today |
|---|---|---|
| inline table `{ a = "b" }` | `dict` | **dropped silently** — the live `asserts` case |
| float `1.5` | `float` | **dropped silently** |
| array of tables `[[artifact.x.files]]` | `list[dict]` | **worse than dropped** — emits the Python `repr` (`{'a': 'b'}`) as the value, so a downstream `mf` lookup returns plausible-looking garbage rather than nothing |
| bool `true` | `bool` | emitted, but as `True`/`False` — `isinstance(True, int)` is `True` in Python, so it passes the scalar branch and renders in Python spelling, not TOML's |

### 2.2 Why the existing guards do not catch it

The header comment above `manifest_flat` says:

> Anything the manifest gains that this does not know about is ignored here and
> caught by the schema guard below, never silently half-consumed.

That is not what the code does. The schema guard checks one thing:

```python
if schema != 1:
    sys.exit(...)
```

So a **new schema version** is caught, and a **new artifact kind** is caught — the
`*)` arm of the `case` in `verify_all` dies rather than skipping, and that
assertion is one of the suite's three named regression locks. But a **new key
inside schema 1** is caught by nothing. The comment describes an intent the guard
does not implement.

**The defect is that asymmetry, not the missing `asserts` handling.** The script
already argues, in its own words, that "a kind the script has not been taught is
content it cannot verify." The identical sentence is true of a key, and the key
path is the one with no assertion behind it.

### 2.3 Why this is not urgent

Exposure today is nil, for two independent reasons:

1. The only dict-valued key in the manifest is `asserts`, and the producer checks
   it: `bin/channel.py::_verify_asserts` runs inside the channel's `cmd_verify`,
   refuses an assertion naming an unpublished artifact, refuses any operator other
   than `>=`, and compares versions. It is not decorative.
2. The live assertion is `myconv >= myclickup 0.3.0` and the channel carries
   myclickup 0.6.0, so it is satisfied with room to spare.

What is left is the shape of the trust, not a live hole: a security-relevant field
crosses the boundary and only the producer inspects it. `vendor-tools.sh`'s own
header calls that pattern out by name — "a transfer of trust dressed as a
simplification" — in the argument for keeping the content diff. The same reasoning
applies here, which is why this is worth closing even though nothing is bleeding.

## 3. RE-INVESTIGATE FIRST — the moving pieces

**Do not implement from §4 without re-running §3.** Four of the seven items below
have already moved once since the channel was built, and this item is deliberately
being parked rather than fixed on the spot, so the gap between capture and
implementation is open-ended. Everything here is offline and read-only.

The channel is a **separate repo on a separate cadence** (`~/repo/nranthony/depot`,
resolved via `$DEPOT_DIR` or `.depot-dir.local` — never a hard path; the root moved
once already, on 2026-08-14, and that move is what let a three-release wheel drift
go green). Facts recorded here are facts about *that* repo as of 2026-08-17.

### 3.1 What does the manifest carry now?

```bash
DEPOT=$(awk 'NF && $0 !~ /^[[:space:]]*#/ {print; exit}' .depot-dir.local)
sed -n '1,20p' "$DEPOT/manifest.toml"      # schema line + first artifact
grep -c '^\[artifact\.' "$DEPOT/manifest.toml"
```

As of 2026-08-17: `schema = 1`, two artifacts (`myclickup` kind `wheel+skill`,
`myconv` kind `plugin`).

*If `schema` is no longer 1*, this work item is likely superseded — the schema bump
forces a consumer-side review anyway, and the key-coverage question should be
folded into that review instead of landed separately.

### 3.2 Does the consumer still drop anything?

Re-run the probe rather than trusting the table in §2.1. It reproduces
`manifest_flat`'s type test exactly and prints only what falls through:

```bash
DEPOT=$(awk 'NF && $0 !~ /^[[:space:]]*#/ {print; exit}' .depot-dir.local)
python3 - "$DEPOT/manifest.toml" <<'PY'
import sys, tomllib
doc = tomllib.load(open(sys.argv[1], "rb"))
for name, art in sorted(doc.get("artifact", {}).items()):
    for key, val in sorted(art.items()):
        if isinstance(val, (str, int)) or isinstance(val, list):
            continue
        print(f"DROPPED  {name}  {key} = {val!r}  (type {type(val).__name__})")
PY
```

2026-08-17 result: one line, `myconv asserts`. *An empty result does not close this
item* — it means the live manifest happens to carry no dict today, while the
`else`-less branch that drops it is still there.

### 3.3 Has the producer's key set or its own checking moved?

```bash
DEPOT=$(awk 'NF && $0 !~ /^[[:space:]]*#/ {print; exit}' .depot-dir.local)
grep -n 'SCHEMA\s*=' "$DEPOT/bin/channel.py"
sed -n '/^    order = \[/,/^    \]/p' "$DEPOT/bin/channel.py"
grep -n '_verify_asserts' "$DEPOT/bin/channel.py"
git -C "$DEPOT" log --oneline -- bin/channel.py manifest.toml | head
```

As of 2026-08-17 the producer's fixed key order is:

```
kind, version, source_repo, source_commit, wheel, wheel_sha256, skill,
skill_sha256, tree, tree_sha256, asserts, proposed_allow, proposed_ask,
proposed_deny
```

Two things to read off this:

- **New keys in that list that the consumer ignores** are new instances of this
  finding. Note that `proposed_allow`/`proposed_ask`/`proposed_deny` are ignored by
  `manifest_flat`'s *callers* too, but deliberately — they are read separately by
  `do_permissions`, which is report-only by design. Do not "fix" those.
- **If `_verify_asserts` is gone or weakened**, §2.3's first mitigation is gone with
  it and the priority of this item rises sharply. Check this before assuming the
  producer still has our back.

### 3.4 Have new artifacts or kinds appeared?

```bash
DEPOT=$(awk 'NF && $0 !~ /^[[:space:]]*#/ {print; exit}' .depot-dir.local)
grep -n '^kind = ' "$DEPOT/manifest.toml"
ls "$DEPOT"                      # member dirs present but not yet published
tail -20 "$DEPOT/RELEASES.md"
```

As of 2026-08-17 the channel root also holds a `paperbridge/` member that the
manifest does **not** publish. If it — or anything else — has since been published,
it may introduce a third `kind`, which changes the shape of §4 Option A (a per-kind
key allowlist has to enumerate it) and means `member_pointer` in `vendor-tools.sh`
needs a line for its `source_repo` too, or its content half degrades to `HASH-ONLY`.

### 3.5 Has `vendor-tools.sh` itself changed?

Line numbers are deliberately omitted from §2 and §4 because they will drift.
Locate by name:

```bash
grep -n 'manifest_flat\|verify_all\|unknown artifact kind\|isinstance' scripts/vendor-tools.sh
git log --oneline -- scripts/vendor-tools.sh | head
```

If the extraction point has been restructured, re-derive the finding before
implementing against it — the fix belongs wherever the type test now lives.

### 3.6 Has the test fixture gained a dict-valued key?

```bash
sed -n '/^regen_manifest()/,/^}/p' scripts/vendor-tools.test.sh
bash scripts/vendor-tools.test.sh | tail -3
```

As of 2026-08-17 the fixture manifest carries **no** dict-valued key at all, which
is precisely why 57/57 passes over a gap that is really there. Whatever §4 option
is chosen, the fixture has to grow one — otherwise the new behaviour is untested in
both directions.

### 3.7 Is the cross-repo relationship still what §2.3 assumes?

The consumer/producer split assumed here is myclickup's ADR-0014 and work/0016
(the ADR lives in that private repo, which is why [AGENTS.md](../../AGENTS.md)
links `docs/adr/` bare). If the channel contract has since been written down
somewhere authoritative — a schema doc, a consumer contract, an ADR on the depot
side — **that document decides §4, not this file.** Check for it first:

```bash
DEPOT=$(awk 'NF && $0 !~ /^[[:space:]]*#/ {print; exit}' .depot-dir.local)
ls "$DEPOT"/docs/adr/ 2>/dev/null; grep -rn -i 'schema\|consumer' "$DEPOT/AGENTS.md"
```

## 4. Design options — provisional, decide after §3

The real decision is **coupling**, not code. A strict consumer breaks the moment
the producer adds a benign key; a permissive one is what this item is complaining
about. Where that line belongs depends on the publish cadence and on who is on the
other side at the time — both §3 questions.

**Option A — strict key allowlist per kind, unknown key FAILS.**
Mirrors the unknown-kind lock exactly, which is the argument for it: the same
sentence justifies both, and the asymmetry is the defect. Cost: every additive
publish is a breaking change here until this repo is updated, and the failure lands
on whoever runs `just tools-check` rather than on whoever published.

**Option B — no key is silently lost; unknown key REPORTS, does not fail.**
Add the missing `else` and a `[NOTE]` line naming the artifact, key, and type.
Keeps additive publishes non-breaking; makes the blindness visible without making
it fatal. Cost: a report is only as good as the person reading it — and this repo's
own AGENTS.md records that a green summary printed over a check that never ran is
the exact failure that started the boundary-monitor work.

**Option C — actually consume `asserts` on this side.**
Enforce the version assertion against what the lock records, so a myconv requiring
a myclickup the image does not have fails here. Closes the trust transfer rather
than merely reporting it. Cost: a second implementation of the producer's semantics
(`>=` parsing, version comparison), which is the cross-repo duplication that
[ADR-0014](../../AGENTS.md) exists to reduce — the same objection that made
`tree_hash` invoke the channel's own `bin/dirhash.py` instead of reimplementing it.
Weigh whether the assertion can be evaluated from `VENDORED.lock` alone (it names
every artifact and version, so probably yes) before accepting that cost.

**Provisional lean: B now, A or C only if §3 shows the producer-side check has
weakened or a second consumer has appeared.** B is the smallest change that makes
the header comment true, and it does not create a breakage the publisher cannot
see. This lean is explicitly *not* a decision — it was formed on 2026-08-17 without
knowing what §3 will say.

If A or C is chosen, it decides a class rather than a case, and warrants an ADR
here (a cross-repo contract is exactly ADR-tier per [ADR-0001](../../docs/adr/0001-provenance-tiers.md));
B does not.

## 5. Steps, once §3 is answered

1. Re-run §3.1–§3.7 and record the answers in a `notes.md` beside this file.
2. Pick an option in §4 on that evidence; open an ADR first if it is A or C.
3. Fix the type test in `manifest_flat` so that no TOML value shape can pass
   through unrepresented — including the `list[dict]` case, which today does not
   drop but stringifies a `repr` into the table, and the `bool` case, which renders
   in Python spelling.
4. Extend `regen_manifest` in `scripts/vendor-tools.test.sh` to carry a dict-valued
   key, and assert the chosen behaviour **in both directions**: the known key is
   handled, an unknown one produces the chosen outcome (fail or report). A one-sided
   assertion here would pass against the current no-dict fixture and prove nothing.
5. Correct the header comment above `manifest_flat` to describe what the guard
   actually does — it currently claims coverage the schema check does not provide.
6. `bash scripts/vendor-tools.test.sh`, then `just test-offline`, then
   `scripts/profile.sh <p> verify`.
7. Commit with a SECURITY IMPACT line. If the outcome changes what the channel may
   publish without breaking this consumer, say so on the depot side too — a
   contract only one repo knows about is the failure mode this whole boundary was
   built to stop.
