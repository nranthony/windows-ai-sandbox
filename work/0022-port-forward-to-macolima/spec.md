# 0022 — Port this repo's work forward to macolima

**Status: Stage 2 COMPLETE 2026-08-31 — awaiting Mac-side execution (stage 3).**
The handoff document is written and indexed:
[`docs/handoff-to-macolima-port-forward.md`](../../docs/handoff-to-macolima-port-forward.md).
Nothing further can be done from this host; see §6 for what was done and §10 for
what came out of doing it.

**Originally: Draft — 2026-08-31.** Scoped and measured here; **execution is
partly not ours.** Everything that touches macolima's image or compose needs the
macOS/Colima host, so this item's deliverable in *this* repo is the selection,
the substrate filter, and a handoff document — not the macolima commits.

**Direction:** windows-ai-sandbox → macolima. The reverse item is
[0021](../0021-pull-back-controls-from-macolima/spec.md).

**Three stages, in order** (this is the shape the owner asked for, recorded so
the item is not read as one lump):

1. **Select and filter** — this spec. What goes, what does not, and why.
2. **Implement here what is implementable from here** — §6. A short list: the
   handoff document, the sibling-repo doc corrections, and the two
   already-written-for-macolima artifacts that were never consumed.
3. **Hand off** — §7. A post-implementation document, generated from this
   repo's *then-current* state, sent to macolima on macOS for the build,
   verify, and finish-up steps that can only happen there. Confirmation comes
   back before this item exits.

---

## 1. Where the two repos actually stand

**The port backlog is larger than the commit log suggests, and the plan for it
already exists in the other repo.**

- Last real W→M port: `macolima@5679866`, **2026-07-19** — pnpm pin opt-out +
  Gemini CLI → Antigravity.
- macolima's HEAD, `8d7eceb` (2026-08-23), is **not a port**. It is
  `work/0001-port-from-windows-ai-sandbox/plan.md`: a 144-line, five-phase
  (A–E) plan written from a read-only comparison, marked **Not started**, parked
  "awaiting stopping point in windows-ai-sandbox".

So this item does not start from nothing. It **re-validates and extends
`macolima@work/0001`**, which is still substantially correct. §3 is the
re-diff that plan asked for; §4 is what happened after it was written.

## 2. The filter — nothing crosses without passing this

From `macolima@work/0001` §1, still accurate. Reproduced because it is the part
most likely to be skipped under time pressure:

| Axis | macolima | here | Consequence |
|---|---|---|---|
| Container user | `agent` UID 1000, non-root | root UID 0, rootless `userns=host` | every `/root/...` → `/home/agent/...` |
| Host | Colima VM, 6 GB, virtiofs | WSL2, 48 GB | never copy `mem 20g` / `pids 4096`; macolima keeps `3g` / `2048` |
| GPU | none | `/dev/dxg`, CUDA base | skip GPU detection, the wsl-gpu overlay, the CUDA base |
| State root | `/Volumes/DataDrive/.claude-colima/` | `~/.ai-sandbox/` | path substitution in three places |
| Shell | bash 3.2 (`setup.sh`) | bash 5 | no assoc arrays, no `xargs -r`, `cksum` not `md5sum` |

`docs/sibling-repo-relationship.md` in this repo is the longer form and should
be read alongside it.

## 3. Re-diff of `macolima@work/0001`'s own measurements (2026-08-31)

That plan told itself to "re-diff before executing — W is in flux". Done:

| Plan said (2026-08-23) | Measured 2026-08-31 |
|---|---|
| `seccomp.json` byte-identical | **DIVERGED** — `creat` + its comment (`ce860b3`) |
| `profile.sh` 1724 / 713 | **2136** / 713 |
| `with-egress.sh` 766 / 188 | 1040 / 188 |
| `verify-sandbox.sh` 589 / 236 | 735 / 236 |
| `deny-destructive.sh` 485 / 154 | 736 / 154 |
| `Dockerfile` 560 / 242 | 753 / 242 |
| `allowed_domains.txt` (unstated) | 719 / 278; **32 tagged blocks / 15** |
| offline test suites (unstated) | **10 / 1** |
| `squid.conf` semantically equivalent | **confirmed** — different spelling, same closure of the CONNECT-on-80 hole |
| Phase D "HOLD until W 0011 lands" | **0011 merged 2026-08-24** — Phase D is unblocked |

Two structural corrections to that plan:

- It anchors on `21fdbde`, a HEAD on an unmerged feature branch. That pointer is
  now meaningless. **Anchor on `main@eda42dd` (2026-08-26) instead** — everything
  at or below it is a port candidate, everything above it is §5's exclusion.
- Its §A9 (send checks back here) is four-fifths stale. Corrected in
  [0021](../0021-pull-back-controls-from-macolima/spec.md) §3; that plan's A9
  should be replaced by a pointer to 0021, not executed.

## 4. What landed here after the plan was written

`main` is at `eda42dd` (2026-08-26); HEAD is 21 commits ahead on the
ComfyUI/fal branch. **That split is almost exactly the port / do-not-port line.**

Merged to `main`, and not in `macolima@work/0001`:

| Commit | What | Why it crosses |
|---|---|---|
| `ce860b3` | **seccomp `creat`** — `tar -cf <file>` failed EPERM in every profile ([0017](../0017-tar-cannot-create-archives-seccomp-creat/spec.md)) | Platform-neutral, one syscall, and it restores the byte-identity invariant `docs/sibling-repo-relationship.md` calls load-bearing. macolima has the identical bug today, unreported |
| `e6bca33` | **openssl/libssl3t64 in-layer upgrade**, CVE-2026-45447 | macolima's digest-pinned `ubuntu:24.04` ships the same vulnerable `ubuntu3.4` and has **no openssl handling at all**. Applies unchanged |
| `e9deb82` | **Third hook tier — warn/ask/deny** ([ADR-0008](../../docs/adr/0008-deletion-is-a-human-step.md)) | The plan's A7 anticipated an `ask` tier; it now exists, measured, with the dialect branching |
| `a9c9b6c` | **`converge_agent_policy`** ([ADR-0007](../../docs/adr/0007-policy-templates-are-source-of-truth-for-every-agent.md)) | This *is* the Phase D dependency. Its landing is what unparks the plan |
| `efbf5bd`, `c32e88e` | **webfetch broker**, ADR-0011/0012, `webfetch.test.sh` | The plan's C2 said "add web-read + bin/webfetch"; the design has since settled — peers with no default, read-hosts-only, keys in headers never URLs. Port the settled version, not C2's sketch |
| `75748f4` | **`private-names-check.sh`** + [ADR-0009](../../docs/adr/0009-public-repo-names-are-searchable-not-absent.md) | macolima's `CLAUDE.md` and README carry the same client names, with the same public-repo exposure and no check |
| `a5af6ee` | **myclickup/myconv 0.7.0 via `vendor-tools.sh`** | Collapses the plan's C1 from two per-payload vendor scripts to one channel door |
| `ccf27a3` | **depaudit repo-root enumeration** — 11 scanned repos was really 16 ([0018](../0018-depaudit-misses-repos-whose-manifest-is-not-at-the-root/spec.md)) | Must travel **with** A6, not after it. The unfixed version under-reports silently, which reads exactly like a clean scan |

Plus one row that goes forward and was mis-filed as a gap in the other
direction: **`proxy/gated_blocks_default_off`**. This repo's version carries an
`ACCEPTED_OPEN_TAGS` set; macolima's `planning_mode_commented` has no equivalent
and cannot distinguish a deliberately-open block from a leak.

## 5. What must NOT cross

The 21 unmerged commits above `main@eda42dd`: ComfyUI (`[comfyui]`,
`[comfyui-models]`, `[comfyui-models-extra]`), `[pytorch]`, `[fal]`, `[nvidia]`,
`genmedia` + `ffmpeg` + `libgl1` in the image, CPython 3.12/3.13 baked via uv.

This is a GPU/ML stack for a 48 GB WSL2 host with `/dev/dxg`. Colima at 6 GB with
no GPU has no use for any of it and the image growth is a straight loss. **Skip
the branch entirely.** If macolima ever wants media tooling it is a fresh item
against that substrate, not a port.

Also excluded, per `macolima@work/0001` §1's "judgement calls, default no":
`glab` (removed there deliberately), beads, the PDF/OCR stack, and every
profile-specific allowlist block.

## 6. Stage 2 — what is implementable from here — **DONE 2026-08-31**

Short list. Everything else needs the Mac. All four items closed; two of them
produced findings that changed the handoff (§10).

- ✅ **S2-a. Correct `macolima@work/0001` in place** — DONE (uncommitted in that repo). — re-anchor it on
  `main@eda42dd`, fold in §3's measurements and §4's table, replace its §A9 with
  a pointer to [0021](../0021-pull-back-controls-from-macolima/spec.md), and mark
  Phase D unblocked. This is an edit in the *other* repo but needs no Mac.
- ✅ **S2-b. Two artifacts written for macolima that it never consumed** — DONE, and the verdict SPLIT; see §10. — both
  already in the bash-3.2/POSIX-awk subset, both sitting here unread:
  `docs/handoff-to-macolima-subnet-allocator.md` (the Phase A1 allocator, with
  its two known bugs called out in §5) and `sync-agent-notice.sh` +
  `sandbox_templates/common/agent-notice.md`. Verify they are still current
  against this repo's code before they travel — the notice in particular has
  moved since it was written for that audience.
- ✅ **S2-c. `docs/sibling-repo-relationship.md`** — DONE. — add the divergences the last
  two comparisons kept rediscovering: allowlist wildcards as INFO-not-DRIFT
  ([0021](../0021-pull-back-controls-from-macolima/spec.md) §6), the hook
  write-protect asymmetry, and the tag-count / test-suite-count gap. Also fix its
  "Quick cross-check commands" block, which still tells the reader to expect a
  clean `seccomp.json` diff.
- ✅ **S2-d. Prepare the handoff document** — DONE, indexed in `docs/index.md`.

Nothing in stage 2 changes this repo's runtime, so it carries no rebuild.

## 7. Stage 3 — the handoff document

**Deliverable:** one document, generated from this repo's state at the moment
stage 2 closes, sent to macolima on macOS. It is the thing that makes the
Mac-side work executable by someone who is not holding this comparison in their
head.

It must carry, and this list is the acceptance criterion:

1. **The anchor commit** it was generated from, so a later reader can tell what
   it does and does not cover.
2. **The §2 substrate filter**, verbatim — it is the part that turns a copy into
   a correct port.
3. **Per phase, the ordered file list and the exact substitutions** (`/root` →
   `/home/agent`, state root, resource limits), not just "port Phase A".
4. **The verification each phase owes**: `PROFILE=_test docker compose config`
   clean, `just --list` parses, `setup.sh <p> --verify` green on a live profile,
   the ported `*.test.sh` green offline, tier-2 audit JSON saved with no new
   DRIFT against the pre-port baseline.
5. **The test suites, first, not last.** 10 here to 1 there is the single
   highest-leverage row in the backlog, and `agent-policy.test.sh` (53),
   `with-egress.test.sh` (82), `webfetch.test.sh` (90) and `vendor-tools.test.sh`
   (65) are all offline — no docker, no network, no `agy`, no `claude`. They port
   and run on the Mac without Colima being up, and they encode findings macolima
   cannot rediscover on its own.
6. **What was deliberately excluded and why** (§5), so its absence is not read as
   an oversight and re-litigated on the Mac.
7. **The open questions that need a Mac answer** — the `agy` sign-in against the
   new allowlist and the `pnpm --version` check from `5679866` are still
   unverified there (see the `macolima-agy-pnpm-port-pending-mac-verify` note),
   and Phase D's hook work must be verified in a *built* image, which is that
   plan's own recorded caveat.

**Exit:** confirmation comes back from the Mac side — phases applied, verify
green, anything that did not port and why. Only then does 0022 archive to
`docs/_archive/`, and only then does
[0021](../0021-pull-back-controls-from-macolima/spec.md) become safe to
re-measure.

## 8. Recommended sequence

`macolima@work/0001`'s A–E ordering is sound. Four adjustments:

1. **A parity hotfix PR first, ahead of Phase A**: seccomp `creat` + the openssl
   upgrade line. Two files, no substrate risk, both closing real defects, and the
   seccomp one restores the byte-identity that makes every future cross-check
   meaningful. The plan has no slot for it because both landed after it was
   written.
2. **Phase A as written**, with A6 taking `ccf27a3` folded in.
3. **Phase D is unblocked** — port 0010 + 0011 as one unit, as that plan
   insists; 0010 alone reproduces the create-only inconsistency 0011 fixes.
4. **Phase E stays per-block and per-profile.** Nothing from §5. `[web-read]`
   travels with the broker in C2, not on its own.

## 9. Definition of done

1. §6 stage-2 items complete in this repo (and S2-a in macolima's tree).
2. The §7 handoff document written, anchored, and sent.
3. Mac-side confirmation received and recorded in this item's `notes.md`.
4. Result reported back here so the implementable-from-here steps can be agreed
   — the owner's stated next conversation.
5. Item archived to `docs/_archive/` per the exit rule; the durable rules it
   produced folded into `docs/sibling-repo-relationship.md`, not left here.

## 10. What stage 2 turned up

Two of the four items produced findings that changed the handoff. Recorded here
because they are the reason stage 2 was worth doing separately rather than
folding into the handoff draft.

### 10.1 The subnet allocator is current — verified, not assumed

`docs/handoff-to-macolima-subnet-allocator.md` was written 2026-06-09, and
`profile.sh` has since grown from ~700 to 2136 lines, so the doc's §4 drop-in
was the obvious staleness risk. It is not stale: §4 is **byte-identical to live
`profile.sh:1008-1083`** — 57 code lines, comments ignored, all five functions
(`octet_start`, `sibling_octets`, `first_free_octet`, `ensure_subnet_octet`,
`ensure_octet_free`). It travels verbatim.

### 10.2 The agent notice does NOT travel, and its own test cannot say so

`sandbox_templates/common/agent-notice.md` passes `agent-notice.test.sh` 13/13
here and is still wrong for macolima in three ways: the title names
`windows-ai-sandbox`, five `/root` paths need substitution, and **lines 133–152
are a WSL2/CUDA section** (`/dev/dxg`, `/usr/lib/wsl`, `CUDA_VERSION=12.6.3`,
`LD_LIBRARY_PATH` ordering) describing hardware macolima does not have.

The suite cannot catch this. Its two locks are *no repo-relative path* and *no
host-side mechanism* — both frame-of-reference rules, neither a substrate-
applicability rule. A notice that confidently explains a GPU to an agent on a
GPU-less host is the same class of defect the suite exists to prevent (the
notice is read on filesystems where this repo does not exist), just on an axis
it does not cover.

**Follow-on candidate, not opened here:** a third lock asserting the notice
carries no substrate-specific claim outside a marked, strippable block. That is
a design change to the notice's structure, so it belongs in its own item rather
than widening this one. Flagged for the owner.

`scripts/sync-agent-notice.sh` itself is clean — zero bash-4 constructs, and its
header already documents the macolima portability intent.

### 10.3 Two bash-4 hazards, five sites

`mapfile` is bash 4+: `scripts/webfetch.test.sh` lines 124, 150, 169 and
`scripts/private-names-check.sh` lines 53, 63. Whether they matter depends on
what `/usr/bin/env bash` resolves to on the Mac — a §8 question in the handoff,
not an assumption. The rewrite is mechanical. The other eight offline suites are
clean.

### 10.4 The cross-check commands in `sibling-repo-relationship.md` were wrong

Three defects, all now fixed: `diff seccomp.json # expect no diff` has been
false since 2026-08-29; a raw `allowed_domains.txt` diff is noise across 32-vs-15
tagged blocks (replaced with a tag-set comparison, filtered for the two prose
fragments `[tag]` and `[a-z-]` that a naive grep picks up); and the probe
comparison was file-level, which is precisely what made `macolima@work/0001`
§A9 four-fifths wrong — it now points at `work/0021` §2's check-level
extraction.
