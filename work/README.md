# work/ — in-flight implementation artifacts

Design-layer plans for work that is **currently in flight**. One folder per work item,
`NNNN-slug/`, holding `spec.md` (what/why, when it needed pinning down — this is also
where a new proposal starts, carrying a `Draft → Accepted → ADR-NNNN | Rejected` status
line; see [ADR-0010](../docs/adr/0010-one-proposal-home-close-the-rfc-tier.md)) →
`plan.md` (design + ordered steps) → `notes.md` (execution log).

Adopted 2026-07-31 — [ADR-0001](../docs/adr/0001-provenance-tiers.md).

## The exit rule — this is the point of the directory

**When a work item's changes merge, archive its folder's durable content to
[`docs/_archive/`](../docs/_archive/)** — the same destination the table below
gives for completed work. (This used to say `work/archive/`, a directory that was
never created; the first item to exit went to `docs/_archive/`.)

A stale `plan.md` left in the tree quietly poisons future agent context: it reads as
current intent long after it stopped being true. The two root-level `IN_TRANSIT_*` /
`REPO-SCAN_*` files this tier replaced are the worked example — both carried a
hand-written "delete this when done" note, and both were still sitting at the repo root
weeks after their content went stale.

## What does *not* go here

| Kind | Home |
|---|---|
| A decision and its rationale | [`docs/adr/`](../docs/adr/) — append-only |
| Raw unprocessed external input | [`docs/incoming/`](../docs/incoming/) |
| How-to procedure | [`.agents/skills/`](../.agents/skills/) |
| Completed work worth keeping | [`docs/_archive/`](../docs/_archive/) |

## Current items

| # | Item | Status |
|---|---|---|
| [0003](0003-repo-scan-audit/plan.md) | Repo scan — audit + housekeeping | Refreshed 2026-08-24, shelved; execute after the branch merges |
| [0009](0009-the-third-cli-runs-on-bun/spec.md) | opencode as the third in-container CLI (OpenRouter provider) — its runtime is Bun, so unparking is a RECONCILIATION with the existing bun deny surface | **Parked** — corrections folded 2026-08-24; Phase 0 measurement on unparking. **Motivation narrowed 2026-09-03**: model choice (OpenRouter, local) is covered by Claude Code's own `ANTHROPIC_BASE_URL` switch with zero new surface ([0023 §8](../docs/_archive/0023-ollama-sibling-container-spec.md)); this item now stands only if the opencode harness itself is wanted |
| [0012](0012-numerai-profile-enablement/spec.md) | Numerai profile enablement — egress done; credentials + MCP wiring remain | **Parked** — two decision gates (§3) go to the owner before implementing |
| [0013](0013-lan-access-to-in-container-agents/spec.md) | Reaching an in-container agent from a second device on the LAN — the source note's `claude serve --port` mechanism does not exist; ACP is stdio, so the honest transport is SSH, not a published port. Buzz now assessed (§3.5): its harness dials the relay OUTBOUND, so it moots the listener question — but the agent under it runs with none of this repo's tool-level guardrails | **Parked** — decision gates in §5 (D1a/D1b/D2); D1a may close the LAN half with no code |
| [0014](0014-bump-base-image-to-cuda-12.9.1/spec.md) | Bump the shared image base from CUDA 12.6.3 to 12.9.1 (still 12.x, not 13) — the 12.6.3 tag hasn't rebuilt upstream, so its CVE set only clears by bumping the pin | **Parked** — two decision gates (§3); full image rebuild + GPU re-verify on pickup |
| [0015](0015-verify-agy-force-ask-outranks-static-allow/spec.md) | ADR-0008's one open security question: does `agy` honour the hook's `force_ask` over its static `command(git checkout)` allow? Holds the 5-minute interactive probe, both outcomes, the fallback (drop the allow from BOTH lists in one commit), and the ADR write-back | **Open** — measurement is the owner's (interactive `agy`); everything else is scripted |
| [0016](0016-comfyui-into-the-sandbox/spec.md) | Run ComfyUI inside `ai-sandbox-<profile>` and retire `my_comfyui/.devcontainer/`. Carries the model-download host census and the reason CDN hosts must be OBSERVED in Squid's log rather than written from source — proven twice over by `[pytorch]` needing three hosts found one at a time | **COMPLETE — signed off 2026-08-28**, ready to archive. Zero always-on egress opened (69 domains, unchanged); D1 = Manager `network_mode = offline`. §11 corrects D1: offline gates catalogue fetches ONLY, not Manager's dependency self-install and not model downloads — both measured |
| [0017](0017-tar-cannot-create-archives-seccomp-creat/spec.md) | `tar -cf <file>` fails EPERM in every profile — `creat` is one of the 135 syscalls `seccomp.json` denies, and GNU tar 1.35 creates its archive with it. Bisected to the exact syscall against unconfined; `tar -cf - > file` and extraction both work, which is what makes it read as a capability problem it is not | **Draft** — diagnosed and fixed in a throwaway container; the remaining step is the decision to allow a legacy alias for an already-permitted `open` |
| [0018](0018-depaudit-misses-repos-whose-manifest-is-not-at-the-root/spec.md) | `profile.sh deps` scans the workspace root plus each immediate child that has a manifest AT ITS ROOT, so a repo keeping its manifest one level down (my_comfyui → `comfyui/requirements.txt`) is never scanned — and the summary prints the 11 repos it did cover without saying one was omitted. Recursion is constrained by vendored `.venv` trees and by ComfyUI custom nodes shipping their own manifests | **Draft** — root-caused; one design decision (§4) on discovery depth, plus the report-the-skip half that should ship either way |
| [0019](0019-comfyui-mcp-in-the-image/spec.md) | ComfyUI MCP in the sandbox. The spec was written against `comfyui-mcp` (npm, third-party); what shipped on 2026-08-29 is `comfy-mcp` 0.10.0 (PyPI, **Comfy Org** upstream) — one character apart, different ecosystems — installed through `with-egress.sh` with the age gate held and pinned in `requirements.lock`, so no image change is needed and every objection in the original text is N/A. Also refutes §5 D3: a project `.mcp.json` + repo-local `enabledMcpjsonServers` is NOT touched by converge | **Parked 2026-08-31** — egress-primary containment accepted by the owner in place of `ask` rules (§5). Measured the three residuals: `install_node`/`update_comfyui` drive `pip` outside the audit log against always-on `[pypi]` (the one hole egress cannot cover), partner spend is closed while `[comfyui]` is, and the plaintext Comfy Cloud credential store has no deny entry |
| [0020](0020-fal-media-tooling-provisioning/spec.md) | Provision the **`genmedia` CLI** (fal.ai's agent-first runner) inside the sandbox: pinned Bun single-file binary baked into the image against the upstream's own `checksums.txt`, `FAL_KEY` from env only, `[fal]` still gated, a paid submit on the **ask tier**, and `ffmpeg` — absent today, and the media pipeline cannot complete without it. Four collisions the source notes could not see: the documented install is pipe-to-shell (already denied here), `genmedia setup --api-key` puts the key on argv, `genmedia update` would silently replace the pinned binary, and the default skill bundle is 0019 §2.3 again | **Draft** — four decisions taken 2026-08-30 (§6), three open (§7); D1 is one measurement run, blocked only on which profile gets the key |
| [0021](0021-pull-back-controls-from-macolima/spec.md) | Controls to pull BACK from the macolima sister repo into this one — the reverse direction, which nothing here has ever acted on. Four findings survive the substrate filter, and four-fifths of macolima's own candidate list turned out to be renames or already-present checks | **PARKED — re-validate after [0022](0022-port-forward-to-macolima/spec.md).** ⚠ **Whenever this item's status is asked for, say so:** every measurement is against `macolima@8d7eceb`, a repo about to move; 0022 pushes stronger versions of several of the same checks the other way. Re-run §2 before acting on §3. **❗D2 (§5) is flagged open and deliberately undecided** — the one row that would add a control neither repo has; revisit with the §3 re-measurement, do not close on an assumed answer |
| [0022](0022-port-forward-to-macolima/spec.md) | Port this repo's work forward to macolima. Re-validates and extends `macolima@work/0001` (planned 2026-08-23, never started): re-diff done, Phase D unblocked by ADR-0007, anchor moved to `main@eda42dd`. Three stages — select/filter, implement what is implementable from here, then a handoff document for the macOS side | **Stage 2 COMPLETE 2026-08-31** — handoff written and indexed ([docs/handoff-to-macolima-port-forward.md](../docs/handoff-to-macolima-port-forward.md)); nothing further is possible from this host. The 21-commit ComfyUI/fal branch is excluded wholesale (§5); the 10-vs-1 offline test-suite gap is the highest-leverage row. **Awaiting Mac-side execution**; exits only on confirmation back. §10 records what stage 2 turned up — including that the agent notice does NOT travel unchanged and its own suite cannot say so |
| [0024](0024-claude-backend-alpha/spec.md) | Alpha test of Claude Code on the Ollama sibling and on OpenRouter — the *use* of 0023's mechanism. Nine unproven claims (§2: real model, real edits, hook behaviour under a weaker model, the recreate path, OpenRouter at all, the 32K context edge, VRAM across profiles, MCP tool search off, verify on a recreated agent) and a three-part test plan against `nranthony` | **Draft** — opened 2026-09-04; four decision gates (§4) incl. whether local is a Claude Code backend at all (D1) and whether the sibling can run under `seccomp.json` (D4). Runs whenever dropping the VS Code attach is acceptable |
| [0025](0025-notice-says-registries-closed-and-pypi-is-open/spec.md) | The agent notice tells every sandboxed agent the package registries are CLOSED; **PyPI and PyTorch are open and enforced open** (measured 200 from the agent, 82 live domains), so a manifest edit + the allowed `uv run` auto-sync resolves live from PyPI with no age gate and no audit-log entry. Three smaller drifts alongside it (secrets bullet promises `**/credentials`, real rule is `.credentials*`; WebFetch scoping unrealised; Ollama sibling missing). The notice is byte-identical to its template across all 22 targets and 13/13 green — nothing in the suite can see posture drift | **Draft** — opened 2026-09-09; four decision gates (§4), D1 (re-close vs accept-and-document) gates the rest. Root-caused to `f253f9d`, whose message says "both CLOSED" over a diff that opened them. Cross-refs [0019 §5.2](0019-comfyui-mcp-in-the-image/spec.md) (same hole from the other end, recorded 2026-08-31) and [0022 §10.2](0022-port-forward-to-macolima/spec.md) (the other missing notice lock) |
| [0026](0026-vendor-paperbridge/spec.md) | Vendor **paperbridge 0.2.1** — the channel's third artifact and the first with runtime dependencies. `vendor-tools.sh` needed no change (verified: `tools-check` enumerated it and produced both expected lock rows), but four things the producer cannot see do: the **antigravity policy twin** (`agent-policy.test.sh` diffs both lists exactly), **5 of 12 download hosts missing** from egress in the misleading direction, **`uv tool install` re-resolves and ignores paperbridge's lock** so `bibtexparser>=1.4` picks 2.0.0 and ships a green image with a broken BibTeX path, and **`sgmllib3k` as a second sdist-only package** the handoff does not name. Handoff §2's forward-guard rationale does not match the shipped artifact (§3) — no-op here | **Accepted 2026-09-09** — all five gates closed same-day: bake **all** extras · pin via a **generated constraints file** (`uv export` at the published `source_commit`, then `uv tool install -c … -f …`; measured on uv 0.12.5 — 62 pins, and no `--require-hashes` exists on that subcommand, so the two host-built wheels are hash-gated in the Dockerfile instead) · **add** the 5 download hosts · deploy the manifest’s **20/8/2** as proposed · **`force_ask`** for `zotero-delete` (agy caches a plain `ask` as a permanent grant). 15 steps in [plan.md](0026-vendor-paperbridge/plan.md); Phases A–B clear the currently-red `test-offline` |
| [0027](0027-admin-profile/spec.md) | An **admin profile** for the deployment tier: one more `profile.sh` profile with this repo and the depot channel under `/workspace`, its own policy template (push/fetch/pull allowed, everything else unchanged, hook and deletion tiers kept), Squid still in front, **no docker socket**. Replaces the human-ferried handoff loop measured across the 0.7.0/0.8.0/0.2.1 re-vendors — and tightens, rather than loosens, the current practice of running the sandbox side as an unsandboxed host session. `up`/`build`/`verify` stay human by design (the agent that changed the boundary never certifies it) | **Draft** — opened 2026-09-10; five decision gates (§8), D1 (class marker vs fixed name) and D4 (self-converge hazard) gate the mechanism. ADR candidate |
| [0028](0028-instruction-levels-revamp/spec.md) | **Instruction levels revamp.** Triggered by one missing rule (gloss before cite: plain name first, code in parentheses — decided twice upstream, present in 2 of 8 instruction files here) but scoped to the whole stack: eight files an agent reads before acting, no rule present at every level, this repo's `AGENTS.md` at 457 lines against 28–118 elsewhere, and a live notice that differs from its template. Settles *where a rule belongs* — user level is TWO files on this machine (`~/.claude/CLAUDE.md` + the agent notice), and a user-level rule needs both | **Draft** — opened 2026-09-10; four gates (§5), D1 (one source or two files + presence test) and D2 (shrink this `AGENTS.md`) shape the plan. Cross-repo half is ferried; the last such round if [0027](0027-admin-profile/spec.md) lands |

Exited 2026-09-10, merged from `feat/0023-ollama-sibling`:

- **0023 ollama sibling container** — local inference on `sandbox-internal`, GPU
  passthrough, and a model store shared across profiles mounted READ-ONLY in every
  runtime. The agent side turned out to be Claude Code's own `ANTHROPIC_BASE_URL`
  switch (§8) rather than a new CLI, which is why `profile.sh <p> backend` exists
  and why [0009](0009-the-third-cli-runs-on-bun/spec.md) narrowed. Its one owner
  step — the recreate for the agent's `NO_PROXY` — is satisfied; tier-1 `verify`
  passes that line. Whether a local model does useful work here is
  [0024](0024-claude-backend-alpha/spec.md), deliberately a separate item.
  → [spec](../docs/_archive/0023-ollama-sibling-container-spec.md) ·
  [plan](../docs/_archive/0023-ollama-sibling-container-plan.md) ·
  [notes](../docs/_archive/0023-ollama-sibling-container-notes.md)

Exited 2026-08-24, all merged the same day (the batch verified by the nine
per-item audits and implemented on `feat/0010-antigravity-guardrails`):

- **0004 deletion is a human step** — ask tier landed (claude `ask` / agy
  `force_ask`), suite 136→207; archived to
  [`docs/_archive/0004-deletion-is-a-human-step-plan.md`](../docs/_archive/0004-deletion-is-a-human-step-plan.md)
  (carries the headless-ask measurements and the rule-11 warn-review evidence).
- **0006 manifest keys** — Option B landed, suite 57→65; archived to
  [`docs/_archive/0006-manifest-keys-plan.md`](../docs/_archive/0006-manifest-keys-plan.md)
  (+ notes).
- **0007 genericise public identifiers** — searchable standard, four fixes +
  `private-names-check.sh`; archived to
  [`docs/_archive/0007-genericise-public-identifiers-spec.md`](../docs/_archive/0007-genericise-public-identifiers-spec.md).
- **0008 the Python half of the gates** — Gate 3 override detection (P01),
  `UV_EXCLUDE_NEWER` window, `deps --vulns`; archived to
  [`docs/_archive/0008-python-half-of-the-gates-plan.md`](../docs/_archive/0008-python-half-of-the-gates-plan.md).
- **0010 antigravity guardrails** — [ADR-0006](../docs/adr/0006-antigravity-is-two-layer-like-claude.md)
  is the durable record; spec+plan archived as
  [`docs/_archive/0010-antigravity-guardrails-spec.md`](../docs/_archive/0010-antigravity-guardrails-spec.md) / `-plan.md`.
- **0011 one policy convergence** — [ADR-0007](../docs/adr/0007-policy-templates-are-source-of-truth-for-every-agent.md)
  is the durable record; spec+plan archived as
  [`docs/_archive/0011-policy-convergence-spec.md`](../docs/_archive/0011-policy-convergence-spec.md) / `-plan.md`.

Exited: **0002 host-side skill slot** — closed 2026-08-24 without implementation
(owner decision): host-side planning stays container-only by design.
`/myconv:make-plan` and `/myconv:wrap-up` remain reachable only inside profiles;
the host agent plans by hand, as it did for ADR-0001. The plan was also written
against `sync-skills-from-conventions.sh`, retired 2026-08-16 for the channel
(`vendor-tools.sh`), so any future revival is a new item against the channel
door — a second mirror destination must sit *inside* its hash gate, and a
`.claude/skills/myconv/` copy would race the seeded plugin name (ADR-0005
§Context 3). Folder was deleted 2026-08-24 (commit `151cebf`); restored
2026-08-25 to
[`docs/_archive/0002-host-side-skill-slot-plan.md`](../docs/_archive/0002-host-side-skill-slot-plan.md)
per ADR-0010's tightened exit rule, so this is closed-without-implementation but
archived, not a standing exception to "archived, not deleted".

Exited: **0001 dependency guardrails** — complete (T00–T26), archived 2026-08-03
to [`docs/_archive/dependency-guardrails-plan.md`](../docs/_archive/dependency-guardrails-plan.md);
the live record is
[`docs/dependency-guardrails-handoff.md`](../docs/dependency-guardrails-handoff.md).

Exited: **0005 cross-repo skill pipeline** — work landed 2026-08-13, §5 closed by
myclickup's reply, archived 2026-08-18 to
[`docs/_archive/cross-repo-skill-pipeline-notes.md`](../docs/_archive/cross-repo-skill-pipeline-notes.md).
Its durable rule — *the detector belongs on the side that owns the stale copy, and
a skip is not a pass* — is maintained in [`AGENTS.md`](../AGENTS.md) under
"Boundary monitors".

## plans/

`work/plans/` is gitignored and holds Claude Code's native plan-mode drafts
(`plansDirectory` in `.claude/settings.json`). Drafts are **not** the durable artifact — a
draft becomes durable by being promoted to a `work/NNNN-slug/plan.md`.
