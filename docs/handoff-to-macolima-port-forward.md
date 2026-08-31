# Handoff → macolima: port the windows-ai-sandbox backlog forward

**Generated:** 2026-08-31, from `windows-ai-sandbox` on the Linux/WSL2 host.
**Anchor commit: `main@eda42dd`** (2026-08-26, *"docs(wrap-up): fold the
myclickup 0.7.0 count into every doc that carried it"*).

**This document covers everything at or below that anchor and nothing above it.**
That boundary is not arbitrary — see §6. If you are reading this after further
work has merged here, re-generate rather than extrapolate: the previous attempt
at this handoff (`macolima@work/0001`, 2026-08-23) anchored on an unmerged
branch HEAD and four of its measurements were stale within eight days.

**Source of this document:** [`work/0022`](../work/0022-port-forward-to-macolima/spec.md)
§7. Its reverse is [`work/0021`](../work/0021-pull-back-controls-from-macolima/spec.md),
which is parked until this handoff comes back.

**You already have a plan.** `macolima@work/0001-port-from-windows-ai-sandbox/plan.md`
is substantially correct and its Phase A–E ordering stands. This document does
not replace it — it re-validates it (§2), adds what landed after it was written
(§3), and supplies the per-phase mechanics it left as prose (§5).

---

## 1. The filter — nothing crosses without passing this

Reproduced verbatim from `macolima@work/0001` §1 because it is the part most
likely to be skipped under time pressure. **A port that fails this table is
worse than no port**: it imports a control whose threat does not exist on your
substrate, or removes one that does.

| Axis | macolima | here | What it means for a port |
|---|---|---|---|
| Container user | `agent` UID 1000, non-root | root UID 0, rootless `userns=host` | every `/root/...` → `/home/agent/...` |
| Host | Colima VM, 6 GB, virtiofs | WSL2, 48 GB | **never** copy `mem 20g` / `pids 4096` / sidecar `2g`. Keep `mem 3g` / `pids 2048` |
| GPU | none | `/dev/dxg`, CUDA base | skip GPU detection, `docker-compose.wsl-gpu.yml`, the `nvidia/cuda` base. Keep your digest-pinned `ubuntu:24.04` |
| State root | `/Volumes/DataDrive/.claude-colima/` | `~/.ai-sandbox/` | substitute in `init-profile-state.sh`, dashboard `docker_client.py`, trivy `emit()` |
| Shell | bash 3.2 (`setup.sh`) | bash 5 | no assoc arrays, no `mapfile`/`readarray`, no `xargs -r`, `cksum` not `md5sum` |

### 1.1 The exact substitutions, counted

Measured 2026-08-31. `/root` → `/home/agent` in the files that travel:

| File | `/root` occurrences |
|---|---|
| `sandbox_templates/claude/hooks/deny-destructive.sh` | 14 |
| `sandbox_templates/claude/hooks/deny-destructive.test.sh` | 14 |
| `sandbox_templates/claude/claude-settings.json` | 5 |
| `sandbox_templates/common/agent-notice.md` | 5 |
| `scripts/audit/probes/antigravity.py` | 6 |
| `scripts/init-profile-state.sh` | 2 |
| `scripts/audit/probes/settings.py` | 1 |
| `sandbox_templates/antigravity/antigravity-settings.json` | 1 |

**Zero occurrences** — these are path-clean and need no substitution:
`scripts/with-egress.sh`, `scripts/agent-policy.test.sh`,
`sandbox_templates/bin/webfetch`, `scripts/webfetch.test.sh`.

### 1.2 bash-4 constructs — five sites, both in test scripts

`mapfile` is bash 4+. If your `/usr/bin/env bash` resolves to macOS stock 3.2
these fail; if you have a Homebrew bash 5 on PATH they do not. **Check before
porting, don't assume:**

| File | Lines |
|---|---|
| `scripts/webfetch.test.sh` | 124, 150, 169 |
| `scripts/private-names-check.sh` | 53, 63 |

The 3.2-safe rewrite is mechanical in all five cases:

```bash
# bash 4                          # bash 3.2
mapfile -t ARR < <(cmd)           ARR=(); while IFS= read -r l; do ARR+=("$l"); done < <(cmd)
```

Everything else in the eight remaining offline suites is clean — checked, zero
hazards in `with-egress.test.sh`, `vendor-tools.test.sh`, `agent-policy.test.sh`,
`depaudit.test.sh`, `dockerfile-order.test.sh`, `profile-skills.test.sh`,
`agent-notice.test.sh`, and `deny-destructive.test.sh`.

## 2. Re-diff of your own plan's measurements

`macolima@work/0001` §0 told itself to re-diff before executing. Done,
2026-08-31:

| Your plan said (2026-08-23) | Measured 2026-08-31 |
|---|---|
| `seccomp.json` byte-identical | **DIVERGED** — `creat` + comment (`ce860b3`) |
| `profile.sh` 1724 / 713 | **2136** / 713 |
| `with-egress.sh` 766 / 188 | 1040 / 188 |
| `verify-sandbox.sh` 589 / 236 | 735 / 236 |
| `deny-destructive.sh` 485 / 154 | 736 / 154 |
| `Dockerfile` 560 / 242 | 753 / 242 |
| `allowed_domains.txt` (unstated) | 719 / 278; **32 tagged blocks / 15** |
| offline test suites (unstated) | **10 / 1** |
| `squid.conf` semantically equivalent | **confirmed**, line by line |
| Phase D "HOLD until W 0011 lands" | **0011 merged 2026-08-24 — Phase D is unblocked** |

Two corrections to that plan, beyond the numbers:

- **Re-anchor it.** It points at `21fdbde`, a HEAD on an unmerged feature
  branch. Use `main@eda42dd`.
- **Its §A9 is four-fifths wrong.** It listed five checks to send back to us;
  `external_dns_blocked`, `connect_80_blocked` (we dropped the `H1_` audit
  prefix, which is what made it look absent), the `bwrap`/`socat`/`ssh` triad and
  the `--show-origin` credential.helper sweep are all already here, and non-root
  UID is inapplicable to our substrate. **Replace §A9 with a pointer to our
  `work/0021`**, which holds the corrected four-row result. Do not execute A9.

**On `squid.conf`:** you spell the CONNECT gate `deny CONNECT !SSL_ports`, we
spell it `allow CONNECT SSL_ports allowed_domains` + `deny CONNECT`. Both close
the port-80 tunnel. **Neither is a finding and neither should be changed** to
match the other.

## 3. What landed here after your plan was written

All merged to `main@eda42dd` or below. None of it is in `macolima@work/0001`.

| Commit | What | Why it crosses |
|---|---|---|
| `ce860b3` | **seccomp `creat`** | `tar -cf <file>` fails EPERM in **every profile** — you have this bug today and have not reported it. Platform-neutral, one syscall. See §5.0 |
| `e6bca33` | **openssl/libssl3t64 in-layer upgrade** (CVE-2026-45447) | your digest-pinned `ubuntu:24.04` ships the same vulnerable `ubuntu3.4`, and you have **no openssl handling at all** |
| `e9deb82` | **third hook tier — warn/ask/deny** (ADR-0008) | your A7 anticipated an `ask` tier; it exists now, measured, with the dialect branching |
| `a9c9b6c` | **`converge_agent_policy`** (ADR-0007) | this **is** your Phase D blocker. It landed |
| `efbf5bd`, `c32e88e` | **webfetch broker**, ADR-0011/0012, `webfetch.test.sh` | your C2 said "add web-read + `bin/webfetch`". The design has since settled — backends are peers with no default, read-hosts-only, keys in headers never URLs. Port the settled version, not C2's sketch |
| `75748f4` | **`private-names-check.sh`** + ADR-0009 | your `CLAUDE.md` and README carry the same client names with the same public exposure and no check |
| `a5af6ee` | **myclickup/myconv 0.7.0 via `vendor-tools.sh`** | collapses your C1 from two per-payload vendor scripts to one channel door |
| `ccf27a3` | **depaudit repo-root enumeration** — 11 scanned repos was really 16 | must travel **with** A6, never after. The unfixed version under-reports silently, which reads exactly like a clean scan |

One row goes forward that your plan filed as a gap in the other direction:
**`proxy/gated_blocks_default_off`**. Ours carries an `ACCEPTED_OPEN_TAGS` set;
your `planning_mode_commented` cannot tell a deliberately-open block from a leak.

## 4. Do the test suites FIRST

**10 suites here, 1 there.** This is the single highest-leverage row in the
backlog and it is also the safest, because these four are fully offline — no
docker, no network, no `agy`, no `claude`, no real channel:

| Suite | Assertions | Needs |
|---|---|---|
| `scripts/webfetch.test.sh` | 90 | nothing (shims `urlopen`) — fix 3 `mapfile` sites |
| `scripts/with-egress.test.sh` | 82 | nothing |
| `scripts/vendor-tools.test.sh` | 65 | nothing |
| `scripts/agent-policy.test.sh` | 53 | nothing |
| `scripts/depaudit.test.sh` | 56 | nothing offline (`--online` adds OSV) |
| `sandbox_templates/claude/hooks/deny-destructive.test.sh` | 207 | ships with Phase A7/D |
| `scripts/profile-skills.test.sh` | 24 | ships with Phase C3 |
| `scripts/agent-notice.test.sh` | 13 | ships with S2-b |
| `scripts/dockerfile-order.test.sh` | 8 | ships with Phase A5 |
| `scripts/private-names-check.sh` | — | fix 2 `mapfile` sites; `[SKIP]`s until `.private-names.local` exists |

They run on the Mac **without Colima being up**, so they can land before any
image work. They also encode findings you cannot rediscover locally — every one
of them exists because something here shipped inverted or drifted silently.

**Caveat that must not be lost:** a suite whose subject you have not ported yet
will fail. Port the suite *with* its subject, not ahead of it. The four in the
"needs nothing" rows above are the exception only for `with-egress.test.sh` if
you take Phase A4 in the same change.

## 5. Per-phase mechanics

Your plan's Phase A–E ordering stands. What follows is the mechanical detail it
left as prose, plus one new phase at the front.

### 5.0 Phase 0 — parity hotfix (NEW, do this first)

Two files, no substrate risk, both closing real defects. Not in your plan
because both landed after it was written.

1. **`seccomp.json`** — add `"creat"` to the basic-I/O syscall group (ours is
   alphabetical: `"creat", "open", "openat", "openat2"`) and carry the comment
   explaining why. This restores the byte-identity that
   `docs/sibling-repo-relationship.md` calls load-bearing, and makes every
   future `diff seccomp.json` meaningful again.
   **Applies at container START** — it takes effect on each profile's next `up`,
   not on write.
2. **`Dockerfile`** — add `apt-get install -y --only-upgrade openssl libssl3t64`
   into the existing install layer, with the comment explaining that the base
   digest has not been rebuilt upstream so re-pulling cannot clear the finding.

**Verify:** `tar -cf /tmp/x.tar .` succeeds inside a recreated container (it
fails today); `trivy` no longer reports CVE-2026-45447.

### 5.1 Phase A — stable, platform-neutral

Take your plan's A1–A8 as written, with these amendments:

- **A1 (subnet allocator).** `docs/handoff-to-macolima-subnet-allocator.md` §4
  was **verified 2026-08-31 as byte-identical to our live `profile.sh:1008-1083`**
  (57 code lines, comments ignored). It is current and safe to consume verbatim.
  Its §5 lists two bugs we hit — `set -e` inside command substitution, and a
  missing `mkdir -p` — that will bite you too.
- **A5 (Dockerfile gates)** must land in the order our
  `dockerfile-order.test.sh` locks: **beads < claude/agy < npmrc (Gate 2) <
  uv/pip (Gate 3)**. `min-release-age` applies at *build* time, so writing the
  npmrc above the CLI install makes `@anthropic-ai/claude-code@latest`
  unresolvable whenever upstream published inside the quarantine window. That
  break is intermittent and surfaces on a routine refresh, not a cold build.
- **A6 (depaudit)** takes `ccf27a3` folded in — see §3.
- **A7 (hook rules)** — see 5.3; do not do the Claude-dialect-only version your
  plan describes, it is superseded.
- **A9** — do not execute. Replace with a pointer to our `work/0021`.

### 5.2 Phase B/C — repo process, templates, vendoring

As written. Two amendments:

- **C1** is simpler than your plan assumed: one `vendor-tools.sh` + `VENDORED.lock`
  against the depot channel, not two per-payload scripts. The channel pointer
  resolves from `$DEPOT_DIR` or a gitignored `.depot-dir.local`, and **the two
  halves of "absent" must not collapse**: nothing configured → loud `[SKIP]`,
  exit 0; configured but missing → **FAIL, exit 1**. Collapsing those turned our
  `test-offline` green over a real three-release drift on 2026-08-14.
- **C2 — `sandbox_templates/common/agent-notice.md` needs a substrate pass, and
  its own test will not catch this.** Ported unchanged it is actively wrong on
  your host: the title names `windows-ai-sandbox`, five `/root` paths, and
  **lines 133–152 are a WSL2/CUDA section** (`/dev/dxg`, `/usr/lib/wsl`,
  `CUDA_VERSION=12.6.3`, `LD_LIBRARY_PATH`) that describes hardware you do not
  have. `agent-notice.test.sh` passes 13/13 on it here because its locks are
  about repo-relative paths and host-side mechanisms, not substrate
  applicability. **Delete the GPU block; do not adapt it.**
  `scripts/sync-agent-notice.sh` itself is clean — checked for bash-4 constructs,
  zero, and it documents the macolima intent in its own header.

### 5.3 Phase D — multi-agent policy (UNBLOCKED)

Your plan says HOLD until W 0011 lands. **It landed on 2026-08-24** (`a9c9b6c`,
ADR-0007). Port 0010 + 0011 **as one unit** — 0010 alone reproduces the
create-only inconsistency 0011 fixes. The three things most likely to be
unified by mistake, each of which is a hole:

1. **The two failure postures are deliberately OPPOSITE.** Claude fails **open**
   (its static `permissions.deny` sits underneath the hook); antigravity fails
   **closed** (for reads the hook IS the control). Claude's pass-through `{}` is
   a **deny** to `agy`, so the antigravity pass must stay an explicit
   `{"decision":"allow"}`.
2. **The ask tier is dialect-branched.** Claude emits
   `permissionDecision:"ask"`; `agy` emits `decision:"force_ask"` — because `agy`
   caches a plain `ask` approval as a permanent Always-Allow grant, so `ask`
   there would mean "prompt once, then delete freely forever".
3. **An unknown `--dialect=` must be fatal** (stderr + exit 2, no stdout). It
   used to coerce to claude, which emits claude-shaped output to a third agent
   and leaves the guardrail installed and inert.
4. **The two convergence write modes must stay OPPOSITE.** Claude overwrites
   (its preferences have repo-local files to live in); `agy` merges (it has none,
   and what it stores there is functional state). Unifying them either destroys
   live `agy` state or lets a stale Claude key survive enforcement.

`deny-destructive.test.sh` (207) locks all of this. **Verify in a *built*
image** — that is your plan's own recorded caveat and it still applies.

### 5.4 Phase E — allowlist, per block and per profile

Adopt our tiered header (PROJECT-PERSISTENT vs PLANNING-MODE, registries
commented by default, the `[tag]` convention) — A4's section parser needs it
anyway. Then reconcile block by block. Measured 2026-08-31:

- **macolima-only, keep:** `[archive]`, `[github-raw]`, `[oa-publishers]`,
  `[paperbridge]`, `[wearables]`, plus your VS Code marketplace/unpkg/update
  entries for the attach flow.
- **Ours worth considering:** `[openrouter]`, `[openai]`, `[google-fonts]`,
  `[citation-tools]`, `[web-read]` (travels with the broker, not alone).
- **Ours to skip:** everything in §6.

One parser trap: **the block-open regex is `\[[a-z-]+\]`**, so a dot or a digit
in a tag makes the block unopenable by `with-egress.sh` — it would sit in the
file looking correct and never open.

## 6. What is deliberately EXCLUDED

Recorded so its absence is not read as an oversight and re-litigated on the Mac.

**The 21 commits above `main@eda42dd`** — the whole ComfyUI/fal branch:
`[comfyui]`, `[comfyui-models]`, `[comfyui-models-extra]`, `[pytorch]`, `[fal]`,
`[nvidia]`, `genmedia` + `ffmpeg` + `libgl1` in the image, CPython 3.12/3.13
baked via uv.

This is a GPU/ML stack for a 48 GB WSL2 host with `/dev/dxg`. Colima at 6 GB
with no GPU has no use for any of it and the image growth is a straight loss. If
you ever want media tooling it is a **fresh item against your substrate**, not a
port of ours.

**Also excluded**, per your own plan's "judgement calls, default no": `glab`
(you removed it deliberately), beads, the PDF/OCR stack (pandoc/WeasyPrint/
tesseract), and every profile-specific allowlist block.

**Not excluded but not ours to send:** `opencode` (our work/0009) stays out until
we unpark it.

## 7. Verification each phase owes

Per `macolima@work/0001` §3, plus the suite obligations:

1. `PROFILE=_test docker compose config` clean; `just --list` parses.
2. `scripts/setup.sh <p> --verify` green on at least one live profile.
3. Every ported `*.test.sh` green offline.
4. Tier-2 audit run and the JSON saved; **no new DRIFT vs the pre-port
   baseline** — capture that baseline before Phase 0, not after.
5. The CLAUDE.md/AGENTS.md editing checklist walked for each touched invariant.
6. Nothing copied without passing §1.

Phase 0 and Phase D additionally need a **full image rebuild and container
recreate** — seccomp applies at container start, and the hook engine is baked
into the image, so a policy-only converge will not carry either.

## 8. Open questions only the Mac can answer

Send these back with the confirmation:

1. **`agy` sign-in against the new allowlist** — still unverified since
   `5679866` (2026-07-19). Does the first console sign-in complete with only
   `daily-cloudcode-pa.googleapis.com` open?
2. **`pnpm --version` inside a repo with a mismatched `packageManager` pin** —
   the other half of `5679866`, also unverified.
3. **Does `/usr/bin/env bash` on your host resolve to 3.2 or 5.x?** Decides
   whether §1.2's five `mapfile` sites need rewriting or just noting.
4. **Phase D verified in a built image**, not a converge — your plan's caveat.
5. **Anything that did not port, and why.** This is the part that feeds our
   `work/0021` re-measurement; a silent omission there costs us a second
   comparison run.

## 9. What comes back

`work/0022` exits on your confirmation, and `work/0021` — the reverse
direction — is **parked until it arrives**, because several of its rows may
resolve themselves once you carry the same three-tier engine. Please report:
phases applied, `verify`/`audit` results, the §8 answers, and the omissions.
