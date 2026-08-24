# 0008 — the Python half of the dependency gates

**Status:** Implemented 2026-08-24 (items 1, 2, 3, 4 — see the per-item notes below).
Raised 2026-08-18 while reviewing a supply-chain plan
written by an agent in `therapod/pipeline`; the findings are about THIS repo, not
that one. **Nothing here is implemented and nothing here is broken today** — every
item is a gap in coverage, which by construction produces no symptom.

**Exit rule:** delete this folder, or move to [`docs/_archive/`](../../docs/_archive/),
when the work merges.

**Security-sensitive.** Items 1 and 2 touch `scripts/with-egress.sh` and
`scripts/depaudit.py`, both on the security-sensitive list in
[AGENTS.md](../../AGENTS.md). Any change needs a SECURITY IMPACT line in the commit,
`bash scripts/with-egress.test.sh` (82/82 after this work; was 66/66) and
`bash scripts/depaudit.test.sh` (43/43 offline after this work; was 38/38) green, plus
`scripts/profile.sh <p> verify`. Run `just test-offline` before calling it done.

---

## 0. How to re-enter this cold

The survey that produced it was a read of the sandbox's dependency controls against
an outside plan that assumed none of them existed. The one-line thesis:

> **Gate 2 (npm/pnpm age quarantine) is defended at three layers. Gate 3 (Python
> wheels-only) is defended at one, and the Python age gate does not exist at all.
> The asymmetry is accidental, not decided.**

Everything below follows from that. Items are ranked; item 1 is the only one I would
call a defect rather than an improvement.

Facts measured on 2026-08-18, all on the HOST (`uv 0.11.16`, Homebrew). Re-measure
before implementing — see §5.

---

## 1. Gate 3 has no project-level override detection (Gate 2 has three)

### 1.1 The finding

`Dockerfile:432-435` documents, as verified, that a project opts out of Gate 3
wholesale:

> `uv` — no per-package exemption key exists. A project opts OUT wholesale with
> `no-build = false` in its own `uv.toml` / `[tool.uv]`; verified to override this
> system default.

Nothing in the repo detects that a workspace has done so. The npm analogue — a
project `.npmrc` beating `/usr/etc/npmrc` — is covered in three places:

| Layer | Gate 2 (npm/pnpm) | Gate 3 (uv/pip) |
|---|---|---|
| `verify-sandbox.sh` at `up` | G10 project-override sweep (`:297-350`) | system files + env + live build probe only (`:403-473`) — **no project sweep** |
| `with-egress.sh` at install | `scan_workspace_rc` (`:319-356`), warns and writes `rc_overrides` into the audit line | **nothing** |
| `depaudit.py` posture | N03 | **nothing** — `no-build = false` appears only as *fix text* at `:710` |

`scan_workspace_rc`'s `find` is the whole story (`with-egress.sh:355`):

```
find "$dir" -maxdepth 4 \( -name .npmrc -o -name pnpm-workspace.yaml \) ...
```

### 1.2 Why it matters, stated precisely

An sdist runs `setup.py`/a PEP-517 backend at INSTALL time. ADR-0004 blocks that
because it is the Python analogue of the npm lifecycle script this image already
blocks. A workspace `uv.toml` carrying `no-build = false` restores that execution
for every install in the window — and the audit record for that window would read
as a clean wheels-only install, because nothing looked. That is the same shape as
the `.npmrc` case `scan_workspace_rc` exists to catch, one ecosystem over, and the
same reasoning as the bracket bug already locked in `with-egress.test.sh`:
**under-reporting is the worst failure mode an audit log has, because it is
indistinguishable from a clean run.**

`verify`'s live build probe (`verify-sandbox.sh:~446`) does not close this: it runs
at `up`, from wherever verify runs, not from the workspace at install time.

### 1.3 Projected change

1. `with-egress.sh` — extend `scan_workspace_rc` to also find `uv.toml`,
   `pyproject.toml` and a workspace `pip.conf`, and classify:
   - `no-build = false` (top-level in `uv.toml`, or under `[tool.uv]`) → `OFF`
   - `only-binary` absent where a workspace `pip.conf` overrides `/etc/pip.conf` → `OFF`
   - `no-binary = <pkg>` → `WEAKER` (pip's per-package exemption; it is narrower
     than uv's wholesale opt-out and should not read the same)
   Keep the existing contract: **never blocks**, emits `path<TAB>key=value<TAB>CLASS`,
   lands in the audit record's `rc_overrides`. A weakened gate is confidence, not a
   boundary, and hard-failing the only install route over it would break installs to
   defend against something reported elsewhere.
   - *Care needed:* `pyproject.toml` is a TOML file, and the existing scanner is a
     line-grep over `key = value`. A `[tool.uv]` section-scoped grep is not the same
     as a top-level one. Decide whether to grep with section awareness in bash or to
     reuse the `python3` already required by this script. Prefer the latter — the
     script already hard-requires `python3` on the host (`:101`) and a naive grep
     would match `no-build` under an unrelated table.
2. `depaudit.py` — a new posture check for the same thing. **Correction 2026-08-24:
   the ID is `P01`, not a new P09.** `P07` is NOT an unexplained gap — it is "Strict CI
   install", deliberately deferred (`docs/rfcs/01-posture-scanner-plan.md:129`,
   `docs/_archive/dependency-guardrails-plan.md:668`). `P01` ("Wheel-only install policy",
   rfcs/01:123) was RESERVED and unimplemented, and is exactly this check. Status `FAIL` when a project disables the wheels-only
   default with no stated reason, `WARN` for pip's per-package `no-binary`. Evidence
   line + file + line number, per the tool's rule that every verdict carries one.
3. `verify-sandbox.sh` — extend the G10 sweep to the Python files, or state in a
   comment why the install-time check is deemed sufficient and G10 stays npm-only.
   Do not leave it undecided a second time; that silence is what produced this item.
4. Tests — new locks in `with-egress.test.sh` and `depaudit.test.sh`. At minimum:
   an inline `[tool.uv] no-build = false` is found (section-scoped, not a bare grep
   hit); a `no-build = false` in a comment or an unrelated table is NOT found; the
   scanner still emits nothing for a clean tree.

---

## 2. Python has no relative age gate — the install window may be the right home for one

### 2.1 Why it has been absent, and what changed

ADR-0002's first re-open condition is *"pip/uv usage grows enough that the missing
Python age gate is the dominant risk."* The blocker was always real and is recorded
in `docs/local-wheels.md:38-58`: `exclude-newer` takes a **timestamp, not a
duration**, so it cannot express "7 days ago" and an image-wide resolution freeze on
an ML sandbox is wrong. It stayed per-project, and per-project means unmaintained —
`dashboard` has carried a P04 WARN since it was written.

Measured 2026-08-18: `uv lock --help` exposes `--exclude-newer` **with an env var,
`UV_EXCLUDE_NEWER`** (and `--exclude-newer-package`). `with-egress.sh` is the only
route a dependency enters a profile by (ADR-0003) and it already knows the moment
the window opens. So the duration→timestamp conversion that `exclude-newer` cannot
express, the install window CAN: compute it per window.

### 2.2 Projected change

Inject into the install command's environment:

```
UV_EXCLUDE_NEWER=$(date -u -d '7 days ago' +%FT%TZ)
```

giving Python the same relative 7-day quarantine npm gets from `min-release-age=7`,
with no image-wide freeze and no per-project maintenance. Record the computed
timestamp in the audit line, so "was this window quarantined" becomes answerable for
Python as it already is for npm.

### 2.3 VERIFIED 2026-08-24 — all three questions answered, favourably

Measured with **uv 0.12.5**, on the host AND inside the image. Nothing here is assumed.

- **Precedence: env > project `[tool.uv]` > user config.** `UV_EXCLUDE_NEWER` beats a
  workspace `[tool.uv] exclude-newer`, so a workspace file **cannot switch the injected
  window off**. Note this is the OPPOSITE of Gate 2 and Gate 3, where the project file
  wins — do not generalise between them.
- **Inert under `--frozen`.** The install plan is byte-identical with and without the
  variable set; `uv sync --frozen` performs no resolution. The install shape we most want
  to encourage is unaffected.
- **Container uv version.** The image carries uv 0.12.5, which honours `UV_EXCLUDE_NEWER`
  and also ships `uv audit` (item 3).

### 2.4 The decision those measurements surfaced

Because env wins, **a project that pins an OLDER (stricter) `exclude-newer` is silently
LOOSENED to the injected window.** That is a real cost and it is taken deliberately: the
alternative — deferring to the project file — lets any workspace disable the gate by
pinning a future date, which is strictly worse.

**Posture adopted:** the project's own pin is READ but never obeyed, and it is written into
the audit line (`py_age_gate.project_pins`) whenever one exists, plus a stderr note when it
is stricter than the window. The record therefore never implies the project's own window
applied. Implemented as `scan_uv_exclude_newer()` in `with-egress.sh`, locked by three
assertions in `with-egress.test.sh`.

### 2.5 The opt-out

`--allow-fresh "<reason>"`. The reason is **mandatory** — a bare `--allow-fresh` exits
non-zero and says so (locked by test) — and it lands in the audit record as
`py_age_gate.reason` with `applied: false`. It exists because a same-week security fix is
real, and a gate with no visible escape hatch gets bypassed *invisibly* instead: someone
runs the install outside this script, where nothing is recorded at all. Making the hatch
loud and logged is the whole point.

## 3. `uv audit` re-prices two ADR-0002 refusals

### 3.1 The finding

ADR-0002 refused the `osv-scanner` binary ("a Go binary to avoid writing a `urllib`
POST") and a local OSV mirror (~240k records to keep fresh). Both arguments were
about **cost**. Measured 2026-08-18, that cost is now zero: `uv audit` exists in uv
0.11.16, reads `uv.lock` directly, and carries `--frozen`, `--output-format json`,
`--service-format osv`, `--service-url`, `--ignore` and `--ignore-until-fixed`. uv is
already in the image and already on the host. No new binary, no vendor, no API key.

What has NOT changed is `depaudit`'s report design (`depaudit.py:938-950`): it
reports `MAL-` records only, because `GHSA-`/`PYSEC-`/`CVE-` answer a different
question and *"mixing them is how a supply-chain gate becomes a CVE treadmill nobody
reads."* That reasoning is intact and this item must not undo it.

### 3.2 Projected change

Wire `uv audit` into `scripts/profile.sh <p> deps` **host-side**, as a separate,
clearly-labelled, **non-gating** section. Constraints:

- It must never merge into depaudit's malicious-package verdict, and never gate
  tier-1 `verify` — `posture` is offline and must stay that way.
- It must not run in-container. `api.osv.dev` is deliberately absent from
  `proxy/allowed_domains.txt`, and ADR-0002 banked "zero new egress surface" as a
  consequence. **Adding osv.dev to the allowlist is not the answer to anything in
  this document.**
- `--ignore-until-fixed` is what makes such a section survivable rather than
  permanently red. Use it, and record what is ignored.
- Deliverable is an **amendment to ADR-0002**, not a new ADR: the refusals were
  priced against a world where a vulnerability scan meant adding a binary or a
  vendor. Say that the price changed, and that the noise argument did not.

### 3.3 Unverified claims to check, not inherit

These came from the outside plan and are **DEBUNKED as of 2026-08-24**:
- `UV_MALWARE_CHECK=1` enabling an opt-in OSV malware lookup on every sync — **does not
  exist** through uv 0.12.5. No `malware` string appears anywhere in its help. Recorded in
  the ADR-0002 addendum so nobody re-inherits it from the outside plan.
- "4–10× faster than pip-audit" — decoration, unverified, do not repeat it.

One thing measured that the plan did not anticipate: `uv audit` prints an *experimental*
banner. That is an argument for keeping the section non-gating, not for skipping it.

---

## 4. This repo fails its own posture check in two places

Measured 2026-08-18 with `python3 scripts/depaudit.py posture <dir>`:

| Subproject | Finding |
|---|---|
| `container_testing/` | **P03 FAIL — no Python lockfile.** It has a `pyproject.toml` and no `uv.lock`; resolution is not reproducible. **FIXED 2026-08-24**: `uv lock` run on the HOST (`download.pytorch.org` is not on any profile allowlist, so locking from inside a profile would need an egress window it should not need). 65 packages, all with wheels — P03 FAIL→PASS and P08 now PASS. |
| `dashboard/` | **P04 WARN — no `exclude-newer`.** `uv.lock` is present and tracked (P03/P08 pass). ~~Resolves as a side effect if item 2 lands.~~ **It does NOT — verified 2026-08-24.** P04 asks whether the *project file* declares a window; item 2 puts the window in the install route instead, where it needs no maintenance. Writing a timestamp into `pyproject.toml` to silence P04 would recreate exactly the unmaintained per-project pin item 2 exists to replace, so the WARN stands and is accurate: outside this sandbox, `dashboard` has no uv-side age gate. |

Both are small. A supply-chain scanner whose own repo does not pass it is an easy
thing to point at, and `container_testing` is the one place here where the outside
plan's headline advice — commit the lock — applies verbatim.

---

## 5. What is explicitly NOT changing

- **`objects.githubusercontent.com` / `release-assets.githubusercontent.com` stay
  commented** in `proxy/allowed_domains.txt:218-224`. This is correct default-deny.
  It does mean `gh release download` inside a profile fails in a misdiagnosable way
  — `github.com` and `api.github.com` are open, so auth and the API call succeed and
  only the asset redirect is denied. That is a runbook line (`with-egress.sh <p>
  --with git -- ...`), **not** an allowlist edit.
- **PEP 740 / attestation verification is not adopted.** `pypi-attestations` carries
  its own dependency tree, which is the thing depaudit's stdlib-only rule exists to
  refuse. Worth recording alongside item 3's ADR amendment, though: ADR-0002's third
  re-open condition — *"artifact-level inspection, rather than name-level, becomes a
  requirement"* — has partly fired already, because `scripts/vendor-tools.sh` now
  does artifact-level content verification for vendored payloads. The ADR's stated
  posture is behind the code. That is an amendment noting what changed, not a
  reversal.

---

## 6. Suggested order

1. **Item 1** — the only defect. Self-contained, testable offline, no network.
2. **Item 4** — trivial, and `container_testing`'s missing lock is a one-command fix.
3. **Item 2** — gated on the three verifications in §2.3. Do not implement before
   they are answered; a wrong precedence assumption here silently disables the gate
   it is meant to add, which is the failure mode this whole item is about.
4. **Item 3** — the ADR amendment is the deliverable; the wiring is a few lines.

## 7. Provenance

Raised from a review of a `therapod/pipeline` agent's supply-chain plan on
2026-08-18. That plan's own content needed correction (it assumed the sandbox had no
Python controls, and carried the two unverified claims in §3.3); the value was in
what its layer model made visible **here** by contrast. No ADR is superseded by this
document — items 2 and 3 propose amendments to ADR-0002 and item 1 implements what
ADR-0004 already decided.

---

## 8. Implementation record — 2026-08-24

Landed in the order §6 asked for (1 → 4 → 2 → 3).

**Item 1** — `with-egress.sh` (`gate3_scan_file`, extended `scan_workspace_rc`),
`verify-sandbox.sh` (G10p sweep + the byte-identical parser copy), `depaudit.py` (P01).
Tests: 6 new in `depaudit.test.sh` (43/43), 13 new in `with-egress.test.sh` (82/82),
including the cross-file drift lock and both section-scope negatives.
The G10 question the plan refused to leave undecided is **decided: G10 was extended**, as
`G10p`. Install-time alone was not enough — `verify` runs at every `up` and is where an
operator looks, and the two checks answer at different moments (what the tree says now, vs
what it said when a window opened).

**Item 2** — `UV_EXCLUDE_NEWER` injected per window, `--allow-fresh "<reason>"` opt-out,
`py_age_gate` in the audit record, `scan_uv_exclude_newer()` for project pins. See §2.3–2.5.

**Item 3** — `scripts/profile.sh <p> deps --vulns` runs `uv audit --frozen` host-side, in
its own labelled section, not merged into depaudit's MAL-only verdict and not affecting the
exit code. Ignore list lives inline in `profile.sh` (`UV_AUDIT_IGNORE`, empty today) and is
applied with `--ignore-until-fixed`. Deliverable: the dated **addendum inside ADR-0002**
(the mechanic ADR-0004 already set, and the one ADR-0002's own Consequences section asks
for), recording the re-priced refusals, the untouched noise argument, the debunked
`UV_MALWARE_CHECK`, and the partly-fired third re-open condition (§5).

**Item 4** — `container_testing/uv.lock` generated and committed; `container_testing/AGENTS.md`
now says the lock is committed, that `uv sync --frozen` is the install shape, and that
regeneration is a HOST-side `uv lock`.
