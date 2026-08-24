# Work-item audit corrections — fold into each doc AFTER 0011 lands

Source: nine independent verification audits run 2026-08-24 (one per work item,
each fact-checked against the tree at `1af2a87` on `feat/0010-antigravity-guardrails`,
live profile state, and upstream docs). Owner instruction: **do not apply until
0011 merges** — 0011 changes facts several of these corrections depend on
(reset-command deletion, convergence semantics), so folding earlier means folding
twice.

Triage rule for this file (per `docs/incoming/` tier): apply the edits below to
each work item's doc, then delete this file. Items whose folders have exited to
`docs/_archive/` by then need nothing.

---

## 0002 — host-side skill slot (`work/0002-host-side-skill-slot/plan.md`)

Preferred outcome: decide option (b) — container-only by design — close the item
with a paragraph and archive it. If instead it stays open, minimum rewrite:

- Exit rule (`plan.md:7`): `work/archive/` → `docs/_archive/` (matches work/README.md).
- Replace `scripts/sync-skills-from-conventions.sh` throughout §Decisions 2 and
  §Investigation — retired 2026-08-16 (`9085ecf`); the door is now
  `scripts/vendor-tools.sh`. Re-scope the question to "does the channel mirror
  loop gain a second destination, INSIDE the hash gate?" (a second door that
  bypasses `verify_all` is the exact failure the door was built to close).
- Drop the bash-3.2/POSIX-awk constraint claim — `vendor-tools.sh` hard-depends
  on python3 by design (its own header, "THE ONE PYTHON DEPENDENCY IS DELIBERATE").
- Re-point Decision 3 from `UPSTREAM.md` revs to `VENDORED.lock` rows —
  `UPSTREAM.md` is now hand-maintained prose; nothing generates it.
- Promote the plugin-name collision (`.claude/skills/myconv/` beside
  `sandbox_templates/skills/myconv/`) from open question to stated constraint,
  citing ADR-0005 §Context 3 (measured: backup wins the name race, fresh copy
  reports Not loaded).
- Add the AGENTS.md security-change protocol as a precondition (the door is
  security-sensitive now: SECURITY IMPACT line, vendor-tools.test.sh green, verify).
- Note ADR-0005 §Decision 5 endorses `.claude/skills/` for project-scope skills —
  option (a) is more defensible than the plan's cost framing suggests.

## 0003 — repo scan audit (`work/0003-repo-scan-audit/plan.md`)

Refresh before executing (and re-verify counts at that time — this list is as of
2026-08-24):

- **Phase 1 method line**: the Security Posture table is NOT in CLAUDE.md (now a
  5-line generated pointer). It is `ARCHITECTURE.md:88` ("## Security posture"),
  and has grown rows for agy tools (ADR-0006), Dependencies (ADR-0003/0004),
  Vendored tools (ADR-0014).
- **Repo characterization**: 100 files/33 md → 222 files/99 md (~44.6%). At this
  size the deferred workflow/fan-out mode is the more defensible default for
  Phases 1–3.
- **Quick wins**: strike win 1 (done), win 2 (moot — no .pyc artifact left;
  current state self-consistent at Python 3.12), and the `numerai-setup.md`
  third of win 3 (deleted in `6591e5a`). Win 5 is a factual error: TWO
  secret-shaped templates exist now — `sandbox_templates/common/db.env.template`
  (moved from `config/`; its own header still says `cp config/…`, itself stale)
  AND `sandbox_templates/common/secrets.env.template` (verified clean).
- **Constants row**: relabel 8080/8501/8188 as devcontainer forwarding (zero
  compose hits); ADD `3128` (squid.conf:9, compose) and `SANDBOX_OCTET`.
- **Staleness suspects**: 3 of 4 `host_setup/*-guide.md` + the docker-bench
  report still frozen at 2025-06-23 (14 months); `setup-rootless-docker-wsl-guide.md`
  was refreshed 2026-07-04 — remove it. ADD `SECURITY_ASSESSMENT.md` (dated
  2026-05-28, "Gemini CLI" authored, indexed nowhere, predates every major
  effort) as the highest-value Phase 2 target.
- Note eight offline suites now mechanically lock a slice of what Phase 1 was
  invented to hand-verify; `docs/_archive/` still has no fencing (unlike
  `archived_script_ref/`, which trivy-scan skips and ARCHITECTURE labels).
- Phase 3 collides with the pending macolima Mac verification (commit 1b8158f).

## 0004 — deletion is a human step (`work/0004-deletion-is-a-human-step/plan.md`)

Reasoning intact; every structural anchor stale. Revise (after 0011, whose
convergence this item needs so new rules actually reach profiles):

- Re-anchor citations, preferring rule NAMES over line numbers (they moved twice):
  emit_block :35→:95; rule 3 :250→:398 (comment :389-397); rule 11 :316→:475
  (comment :474) — :316 is now a DIFFERENT rule (docs-install-cmd);
  philosophy line :186→:337-339; Edit/Write arm ~99-204→:212-353;
  suite 95/95→136/136; profile.sh:517→:589-590; agent-notice.md:26→:30-33.
- "Rule 13's WARN tier" → rule 14 (docs-install-cmd). Rule 13
  (manifest-dep-add) BLOCKS; the hook's own ":332 rule-13 treatment" means block.
- Rewrite "What implementing `ask` costs" for TWO dialects: `emit_ask()` must
  branch — claude → `permissionDecision:"ask"`, antigravity → `force_ask`
  (plain `ask` is cached as a permanent Always-Allow grant; first approval
  unlocks deletion forever). Both test helpers (`assert` :21, `agy_assert` :374)
  need the third decision, and BOTH `case "$want"` blocks lack a default arm —
  today a `want=ask` assertion passes vacuously; add the arm first.
- Decision 1 update: the no-human question is already half-answered for agy, in
  the negative. This item is now the natural home for 0010's deliberately
  deferred `force_ask` (D3) — adopt it or explicitly decline it.
- Decision 6 / investigation 4 rewrite: the literal-prefix `git reset --hard`/
  `git rebase` entries now exist in BOTH static lists
  (`antigravity-settings.json:156-158`), parity is exact/bidirectional/no
  exceptions, and for agy the static list is the tamper-resistant layer — so
  ADD spelling-independent hook rules, never MOVE the entries. Any static `ask`
  addition lands in both files in the same commit or parity goes red.
- Note: `git checkout`/`stash`/`branch` are not "uncovered" — they are on both
  ALLOW lists; this is narrowing an existing grant.
- Note the live inaccuracy found: `antigravity-settings.json:5` claims "the hook
  re-asserts this set as force_ask" — the hook contains no force_ask; the
  comment is aspirational. Fix it in whichever item lands first.
- Add `antigravity-parity.test.sh` (28/28) and `agent-notice.test.sh` (13/13)
  to the green-before-merge gate. The notice suite locks no-repo-relative-path /
  no-host-side-mechanism rules the proposed wording must respect.
- Evidence nit: `git log --diff-filter=D` over `*skills*` is no longer empty
  (two vendor-script retirements match); conclusion unaffected, drop the line.
- Decision 6 (macolima) doubled: macolima now carries the agy port too.

## 0006 — manifest keys (`work/0006-manifest-keys-the-consumer-drops/plan.md`)

**APPLIED 2026-08-24** — implemented (Option B, notes.md written, suite 65/65) in commit 9304cd2; skip at fold time.

The mandatory §3 re-investigation RAN 2026-08-24 and is discharged. Create
`notes.md` beside the plan recording:

- §3.1 schema still 1, two artifacts; myconv now 0.6.0 @ 1b0d8848 (consumer
  current, tools-check green). §3.2 probe: identical single DROPPED line.
  §3.3 producer key order byte-identical; `_verify_asserts` intact at
  channel.py:419, unweakened; no channel.py commits since 2026-08-16.
  §3.4 no new kinds; paperbridge explicitly "not a channel member yet".
  §3.5 vendor-tools.sh unchanged; manifest_flat at :121, else-less pair at
  :133/:135. §3.6 fixture still dict-free; 57/57 green over the gap.
  §3.7 no authoritative contract doc anywhere — this file still decides §4.
- All four §2.1 shapes reproduce empirically; ADD a fifth row: TOML
  date/datetime is also silently dropped (no live exposure).
- Decision: **Option B**, strengthened — producer check intact, no second
  consumer, and depot AGENTS.md now says "no schema or tooling change" for
  additive publishes (argues against Option A's strict-fail coupling). No ADR.
- §1 code sample: version 0.4.0 → 0.6.0.
- §5 step 7 pointer: depot AGENTS.md's "no schema or tooling change" line is the
  natural home for a one-sentence key-contract statement.

## 0007 — genericise identifiers (`work/0007-genericise-public-identifiers/spec.md`)

**APPLIED 2026-08-24** — scope decided (searchable), edits + private-names check landed in commits 75748f4/a9c9b6c; skip at fold time.

- Headline: "9 files, 21 hits" → 13 files / 27 lines (12/26 excluding the
  spec's own self-reference); re-count at fold time — it grows with every landing.
- New occurrences postdating the spec: `work/0008` L4/L248 (`therapod/pipeline`),
  `work/0010` L231 (`fluidmomenta`), `work/0011` L139 (the F6 table — all three
  profile names beside per-profile settings, highest-density disclosure in the
  tree) and L164. All land in the existing "Leave" tier (work/, archives).
- Broken citation: `work/0005-.../notes.md` → archived to
  `docs/_archive/cross-repo-skill-pipeline-notes.md:130` (now 2 names on the line).
- The stated grep is case-sensitive and under-reports: state it as `grep -clEi`.
  It misses `sandbox_templates/common/secrets.env.template:50`
  (`CLICKUP_TOKEN_THERAPOD`) — a shipped template; ADD to the **Do** tier.
- Qualify the `nranthony` carve-out: the README attribution stays out of scope,
  but the handle appearing AS a profile name beside two client names (0011 F6
  table) is a different disclosure the pattern cannot see.
- Promote the lint/CI check from Non-goals to in-scope: four new occurrences in
  six days is the drift rate that justifies it.

## 0008 — Python half of the gates (`work/0008-the-python-half-of-the-gates/plan.md`)

**APPLIED 2026-08-24** — all four items implemented in commit d040d0e (plan §2.3 rewritten to verified); skip at fold time.

- §2.3 rewrite: "verify BEFORE implementing" → "verified 2026-08-24", with:
  (1) precedence measured env > project `[tool.uv]` > user config —
  `UV_EXCLUDE_NEWER` cannot be switched off by a workspace file; record the
  mirror-image decision: a project pinning an OLDER exclude-newer is silently
  loosened to the injected window. (2) `--frozen` is inert — byte-identical
  install plan with/without the var; `uv sync --frozen` safe. (3) host AND
  image both carry uv 0.12.5 with `UV_EXCLUDE_NEWER` and `uv audit` present
  in-container. Item 2 may now move ahead of item 4.
- P07 claim is wrong: P07 = Strict CI install, deliberately deferred
  (rfcs/01:129, _archive/dependency-guardrails-plan.md:668). The right ID for
  the new check is the reserved, unimplemented **P01** (wheel-only install
  policy, rfcs/01:123) — extend it, don't mint P09.
- Item 4 caveat: `container_testing`'s lock needs the pytorch index
  (`download.pytorch.org`, commented at allowed_domains.txt:273) — an egress
  window, not "one command".
- Counts/citations: 58/58 → 66/66; Dockerfile:432-435 → :445-450;
  verify-sandbox G10 :297-350 → :407-487, Python checks :403-473 → :499-585;
  scan_workspace_rc :319-356 → :342-397 (find at :395); python3 require
  :101 → :105; uv install :101-114 → :99-115; githubusercontent comment
  :218-224 → :260-263. depaudit :710 and :938-950 still exact.
- §3.3: `UV_MALWARE_CHECK` absent through uv 0.12.5 — restate as
  debunked-by-absence. Measurement basis header: 0.11.16 → 0.12.5.
- Incidental: `~/.cache/uv/osv-v0/` shows `uv audit` caches its corpus locally —
  relevant to §3.2's host-side non-gating wiring.

## 0009 — opencode/Bun (`work/0009-the-third-cli-runs-on-bun/spec.md` AND `plan.md`)

- **§0 "no existing Bun surface" is FALSE and was false when written** (both
  hits predate the claimed 2026-08-20 verification): 12+ touchpoints — both
  agents' deny lists (`bun add/install/x`, `bunx`), the hook's fetch-and-run
  regex (:304/:308/:316) + four locked test assertions, `settings.py:70`
  required-deny, `agent-notice.md:18` + `agent-notice.test.sh:121` lock,
  `with-egress.sh:264/:564`, `depaudit.py` (Bun first-class), `rfcs/02:218`
  (the exact bunfig minimumReleaseAge gate D5 presents as open), rfcs/01,
  `permissions-model.md:51`. Consequence: unparking is a RECONCILIATION with an
  enforced deny surface (does opencode's runtime Bun install fall under those
  rules? carve-out? what does the notice say?), not an addition. The claim sits
  in the "structural, trust cold" bucket — remove it from there.
- Propagate the 2026-08-23 correction block into `plan.md` (unamended): T01/Q6,
  T10, and the verify assertions all still target the global config at
  precedence level 2 — the path 0011 F8 rejected.
- D2's `reset-opencode` escape hatch is superseded: 0011 deletes all `reset-*`
  for one `just converge`. D2's create-only rationale becomes historical once
  0011 lands.
- §5 re-derive against the two-dialect engine: 95/95 → 136/136, the
  "Claude-tool-shaped regexes" premise is gone; the real question is which way
  the opencode dialect FAILS.
- Counts/cells: "seven suites" → eight (was six at writing; re-check at unpark);
  redraw the §2 table (agy permissions cell "none of ours" at :136 still wrong
  in the body; Detector cell — domains live under a `[gemini]` label in
  proxy.py REQUIRED_DOMAINS, and two allowlist domains are missing from it;
  Version-bump cell — agy has no `--agy-version=` flag, the symmetry may not
  exist).
- D6's "probe count in three README references" confirmed: `65` at README
  :100/:200/:321 (also stale vs 0010 — see below).

## 0010 — antigravity guardrails (`work/0010-antigravity-permissions-and-hooks/spec.md`)

Folder likely exits on merge; apply to the REBUILD COMMIT and to whatever
survives:

- Probe count stale in four places: README.md:100/:200/:321 and justfile:130
  all say 65; real count ~83 with the 18-check antigravity probe. (Pre-existing:
  `.agents/skills/security-audit.md:9` "~80" never agreed with 65 either.)
- DoD row 5 wording: tier-1 does NOT assert `toolPermission` mode — that check
  is tier-2 only (`probes/antigravity.py:120-125`).
- F8's claim that `claude-settings.json` carries `//` comments is false (zero
  found); the parity test's `//`-strip (:57-59, :62, :74) is dead code on a
  false premise — 0011 DoD 5 already owns the cleanup; fix F8's text with it.
- §5's timeout instruction unfulfilled: hooks.json uses 5 (vs claude 2,
  upstream 30) with no stated rationale anywhere — add one line, tied to F6
  (timeout kill fails closed).

## 0011 — one policy convergence (`work/0011-one-policy-convergence-across-agents/spec.md`)

**APPLIED 2026-08-24** — all of the below was folded into 0011's `spec.md` and
`plan.md` the same day (must-fix items, the three decisions — decided as:
`skipAutoPermissionPrompt` rides a one-key preserve list; `converge` prints the
restart instruction when the container runs; the suite is RENAMED to
`agent-policy.test.sh` per plan T07 — and the accuracy items). Kept here only
as the record of what changed; skip this section at fold time.

Note also, same day: 0010's build/up/verify/audit ran — the antigravity probe
is OK on all three profiles, and `template_diff` DRIFT is now measured live
(all three profiles; evidence in
`~/.ai-sandbox/profiles/<p>/claude-home/audits/2026-08-24T*-audit.json`),
which the DoD-4 rewrite cites.

Original list (do these FIRST — everything above waits on
0011 landing, but 0011 itself needs these before implementation):

Must fix (correctness):
- The discarded-keys mechanism does NOT catch the in-session `permissions`
  promotion it claims to (§2 "subsumes the detector"): `permissions` is an
  owned key, never in the dropped set — the fluidmomenta promotion would be
  reverted SILENTLY. Capture owned-key content diffs, or retract the claim.
- DoD 4 / plan T06 describe the wrong defect: `stage-audit-package.sh` runs on
  every `audit` (profile.sh:1395), the staged template exists in all three
  profiles (md5-identical to the template), and an absent file yields UNKNOWN,
  not silence. The real defect: stale `USER_CUSTOMIZATION_KEYS`
  (settings.py:30) has `template_diff` RED on all three profiles today. Fix the
  constant; there is no path problem.
- F4's "No overlap" is false for Claude (Claude writes `allow` rules into
  `permissions` — the spec's own F7 is the proof), and §3 invariant 2 ("never
  overwrite a file the agent writes to") forbids the chosen design. Reword
  invariant 2 to "never overwrite without capturing what the agent wrote."

Decide before implementation:
- `skipAutoPermissionPrompt` ownership (user-or-managed only; no recovery path
  if dropped — template owns it, or the auto-mode notice returns every `up`).
- Converge-under-a-live-session semantics: all three `reset-*` branches end
  "restart the agent to pick up" (profile.sh:1431/:1442/:1454); `just converge`
  "without touching containers" overwrites under a live Claude — a lost-update
  race both ways. State the rule.
- Extended vs renamed parity suite: DoD 5 says extended, plan T07 says renamed
  to `agent-policy.test.sh` (rename touches justfile + ~4 AGENTS.md paragraphs).

Accuracy:
- Contract table's opencode row lists the global-config path F8 itself rejected
  — mark `tbd — F8`.
- F7's quote of permissions-model.md:75-76 is itself stale (19-command surface
  is now 28/17/11 per the template's own `_myclickup_note`; the operative
  control is the `_ask_note` set, not defaultMode:auto) — DoD 6/T08 must also
  correct that doc paragraph. F7's residual list is short one: `undepend`
  (11 ask entries − 3 = 8, not 7).
- DoD 7 partly done (0009 correction block exists; only the :136 table cell
  remains).
- "Yes, and don't ask again" becomes session-scoped under overwrite — state the
  behavioural change explicitly.
- `settings.discarded.json` inside `claude-home/` is agent-writable and inside
  Claude's scan path — consider a host-side location, or at minimum teach
  verify to expect it (cf. the existing no-`*.bak*` assertion).
- Reset-deletion blast radius is larger than DoD 3: verify-sandbox.sh
  :177/:190/:192/:251/:254 print `reset-*` remediation FROM INSIDE containers;
  the DEPLOYMENT paragraph in the shipped template's `_myclickup_note` and
  init-profile-state.sh:82-83 both instruct create-only + reset-settings;
  plus docs/deny-destructive-hook-plan.md:29, sandbox-design-notes.md:30,
  extending-a-profile.md:103/:163, ADR-0006:123, justfile:176-187, profile.sh
  header :29-33 and help :1607.
- ADR-0005: supersede (plan T10 is right), never "amend" (spec DoD 6 wording).
- Also fold: F4's dead `//`-strip cleanup covers 0010 F8's false claim (above).
