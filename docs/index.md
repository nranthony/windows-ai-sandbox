# Documentation Index

## Provenance tiers

Adopted 2026-07-31 ([ADR-0001](adr/0001-provenance-tiers.md)). The chain reads left to
right: a **`work/NNNN-slug/spec.md` proposal** → an **ADR** records → **work/** implements
→ the commit (citing the ADR) is the outcome. The separate `docs/rfcs/` tier closed
2026-08-25 — [ADR-0010](adr/0010-one-proposal-home-close-the-rfc-tier.md) — in favour of
this one proposal home; its five files are kept, unrenumbered, in `docs/_archive/`.

- [docs/adr/](adr/) — decisions and their rationale. Append-only.
  - [ADR-0001](adr/0001-provenance-tiers.md) — adopt these tiers *(Accepted)*
  - [ADR-0002](adr/0002-dependency-guardrail-scope.md) — dependency guardrails: what we deliberately do not build *(Accepted 08-02)*
  - [ADR-0003](adr/0003-strict-egress-default.md) — registries unreachable by default; installs open a bounded window *(Accepted 08-02)*
  - [ADR-0004](adr/0004-python-wheels-only.md) — Python installs are wheels-only; source builds opted into per project *(Accepted 08-03)*
  - [ADR-0005](adr/0005-skill-templates-are-source-of-truth.md) — skill templates are the source of truth; profile copies converge on `up` and keep no backups *(Accepted 08-10)*
  - [ADR-0006](adr/0006-antigravity-is-two-layer-like-claude.md) — `agy` carries the same two layers as Claude; the STATIC deny list is the load-bearing one *(Accepted 08-22)*
  - [ADR-0007](adr/0007-policy-templates-are-source-of-truth-for-every-agent.md) — policy templates are the source of truth for EVERY agent; one converge, per-agent overwrite/merge *(Accepted 08-24, supersedes ADR-0005)*
  - [ADR-0008](adr/0008-deletion-is-a-human-step.md) — deletion is a human step: the shared hook engine has three tiers, and the `ask` tier is dialect-branched (claude `ask`, `agy` `force_ask`) *(Accepted 08-25)*
  - [ADR-0009](adr/0009-public-repo-names-are-searchable-not-absent.md) — public-repo client names: the standard is SEARCHABLE, not "present at all"; archived narrative, evidence-bearing uses and git history are kept *(Accepted 08-25)*
  - [ADR-0010](adr/0010-one-proposal-home-close-the-rfc-tier.md) — one proposal home: `docs/rfcs/` is closed, new proposals are `work/NNNN-slug/spec.md`, the exit rule tightens to archived-not-deleted *(Accepted 08-25)*
  - [ADR-0011](adr/0011-web-read-backends-are-peers-with-no-default.md) — web-read backends are peers: `webfetch --via` is required, no default, and a failure on one backend means switch, not stop *(Accepted 08-26)*
  - [ADR-0012](adr/0012-web-read-backends-get-read-hosts-only.md) — a web-read backend is admitted for its read interface only: exact host, key in header, no passthrough, write-surface siblings named and excluded *(Accepted 08-26)*
- [work/](../work/) — in-flight items AND new proposals, archived on merge ([README](../work/README.md), [ADR-0010](adr/0010-one-proposal-home-close-the-rfc-tier.md))
  - 0001-dependency-guardrails — **complete (T00–T26), archived 2026-08-03**; live record is the [handoff](dependency-guardrails-handoff.md), plan preserved at [_archive/](_archive/dependency-guardrails-plan.md)
  - [0003-repo-scan-audit](../work/0003-repo-scan-audit/plan.md) — audit + housekeeping scan; refreshed 2026-08-24, **shelved**
  - [0009-the-third-cli-runs-on-bun](../work/0009-the-third-cli-runs-on-bun/spec.md) — opencode as a third in-container CLI; **parked**, unparking is a reconciliation with the bun deny surface
  - [0012-numerai-profile-enablement](../work/0012-numerai-profile-enablement/spec.md) — credentials + MCP wiring for the numerai workspace; **parked** behind two owner gates
  - [0013-lan-access-to-in-container-agents](../work/0013-lan-access-to-in-container-agents/spec.md) — reaching an in-container agent from another device; SSH + `attach` is the answer unless a graphical client is wanted; carries the Buzz fit assessment (§3.5); **parked**, owner to revisit
  - [0014-bump-base-image-to-cuda-12.9.1](../work/0014-bump-base-image-to-cuda-12.9.1/spec.md) — base image 12.6.3 → 12.9.1 (not 13); **parked** behind two gates, full rebuild + GPU re-verify on pickup
  - [0015-verify-agy-force-ask-outranks-static-allow](../work/0015-verify-agy-force-ask-outranks-static-allow/spec.md) — ADR-0008's open `[unverified]`: the interactive `agy` probe, both outcomes, the fallback and the write-back; **open**, measurement is the owner's
  - 0004, 0006, 0007, 0008, 0010, 0011 — merged 2026-08-24, archived to [_archive/](_archive/) (listed below); 0002 closed without implementation, restored 2026-08-25 to [_archive/](_archive/0002-host-side-skill-slot-plan.md)
- [docs/incoming/](incoming/) — raw unprocessed input, **unverified** ([README](incoming/README.md)); graduates to `work/`

## Architecture & Security

- [AGENTS.md](../AGENTS.md) — agent conventions: golden rules, security-sensitive files, verification protocol (CLAUDE.md is a generated pointer to it)
- [ARCHITECTURE.md](../ARCHITECTURE.md) — system map: substrates, network model, state layout, security posture, repo map
- [.agents/skills/](../.agents/skills/) — operational guides: profile lifecycle, audit tiers, squid allowlist
- [Sandbox design notes](sandbox-design-notes.md) — why rootfs is rw, bwrap is disabled, container runs as root, git config is denied
- [**Extending a profile**](extending-a-profile.md) — where a tool, skill, plugin, library, key or API has to live to survive a recreate: the three durability classes, the bind-mount-shadows-the-image rule, the seeding seams, and a self-contained brief to hand an agent in another repo that must deploy into a profile
- [Permissions model](permissions-model.md) — deny/allow posture, two-phase workflow, WebFetch exfil risk, hook self-protection
- [**Dependency guardrails — build report, defect log, retrospective**](dependency-guardrails-handoff.md) — the complete slopsquatting-defence effort (phases 0–4, T00–T26) in one self-contained document: what exists and where, the four ADRs, **every defect and how it was caught**, what remains, and the transferable lessons. Written for someone with neither the repo nor the conversation. Start here before changing anything in the guardrail path
- [VS Code integration security](vscode-integration-security.md) — SSH agent forwarding, gitconfig leaks, credential helper injection, orphaned root shells
- [Sibling repo: macolima](sibling-repo-relationship.md) — shared vs divergent posture between the two repos, and how to mine the sister repo for flaws we might miss
- [**Handoff → macolima: port the backlog forward**](handoff-to-macolima-port-forward.md) — the executable form of [work/0022](../work/0022-port-forward-to-macolima/spec.md). Anchored on `main@eda42dd`: the substrate filter with counted substitutions, the five bash-4 sites, per-phase mechanics, the deliberately-excluded ComfyUI/fal branch, and the five questions only the Mac can answer. **Re-generate rather than extrapolate if work has merged since the anchor**
- [Handoff → macolima: per-profile subnet allocation](handoff-to-macolima-subnet-allocator.md) — the bash-3.2-safe allocator (`SANDBOX_OCTET` → `172.30.$OCTET.0/24`) plus the two bugs we hit. §4 verified 2026-08-31 as byte-identical to live `profile.sh:1008-1083`, so it can be consumed verbatim
- [Portability assessment + plan](portability-assessment-plan.md) — running on bare-Ubuntu rootless (validated 2026-07-04, incl. GPU-overlay auto-detect design) and why rootful Docker is a redesign, not a toggle
- [scripts/audit/README.md](../scripts/audit/README.md) — tier-2 structured probe suite (~80 checks, JSON output)
- [seccomp.json](../seccomp.json) — syscall filter (`clone3 → ENOSYS`, `unshare(CLONE_NEWUSER)` blocked)
- [seccomp notes](seccomp-notes.md) — must-keep syscalls, clone3 ENOSYS rule, editing conventions

## Hardening Verification

| Tier | Script | What |
|---|---|---|
| 1 | [`scripts/verify-sandbox.sh`](../scripts/verify-sandbox.sh) | Fast tripwire (40 pass/fail/warn outcomes across 17 check groups on a GPU host; fewer on bare Linux, where the GPU probes report N/A) |
| 2 | [`scripts/audit/`](../scripts/audit/) | ~80 structured probes, JSON output ([README](../scripts/audit/README.md)) |
| — | [`scripts/depaudit.test.sh`](../scripts/depaudit.test.sh) | depaudit regression suite (43 offline, `--online` adds the OSV corpus) over [fixtures](../scripts/depaudit-fixtures/) |
| — | [`scripts/with-egress.test.sh`](../scripts/with-egress.test.sh) | install-window parser suite (82, fully offline — no docker, no network) |
| — | [`scripts/profile-skills.test.sh`](../scripts/profile-skills.test.sh) | `converge_skills` suite (24, offline) — locks backup-pruning, the never-prune-unmanaged rule, and mirror-not-merge convergence ([ADR-0005](adr/0005-skill-templates-are-source-of-truth.md)) |
| — | [`scripts/agent-policy.test.sh`](../scripts/agent-policy.test.sh) | agent-policy suite (53, offline — no docker, no `agy`, no `claude`) — diffs the two static allow/ask/deny lists exactly in both directions, locks that the two hook failure postures stay OPPOSITE, and locks the convergence for BOTH agents: the two write modes stay opposite, the merge never mirrors a directory, the overwrite captures what it drops (owned-key diffs included) and goes quiet when nothing changed, a live preference survives converge while a profile lacking one is seeded the template default, and `--defaults` resets it and captures the replaced value ([ADR-0006](adr/0006-antigravity-is-two-layer-like-claude.md), [ADR-0007](adr/0007-policy-templates-are-source-of-truth-for-every-agent.md)) |
| — | [`scripts/webfetch.test.sh`](../scripts/webfetch.test.sh) | web-read broker suite (90, offline — no docker, no network, no key). Runs the broker as a real subprocess with `urlopen` shimmed, so it measures: no request on a missing key, keys in headers never URLs, every broker host an exact live `[web-read]` line and the write-surface hosts absent, every env var named in the secrets template, `--via` required with no default, banner first on stdout ([web-read-broker.md](web-read-broker.md)) |
| — | [`scripts/agent-notice.test.sh`](../scripts/agent-notice.test.sh) | sandbox-notice content suite (13, offline) — locks the two defects only a consumer repo can see: no repo-relative path, no host-side mechanism. The notice ships into filesystems where this repo does not exist |
| 3 | [`sandbox_templates/skills/audit-sandbox/SKILL.md`](../sandbox_templates/skills/audit-sandbox/SKILL.md) | Agent-side judgment over tier-2 JSON (staged into container by `profile.sh audit`) |
| — | `just check-upstreams` | Boundary monitor, not a test: is every vendored payload current with its upstream? `tools-check` covers all channel artifacts — lock-vs-published (hash) and artifact-vs-source_commit (content, when the member checkout is reachable). Offline; SKIPs loudly where a source is absent. Run by `test-offline` |

## Agent Tool Controls

- [sandbox_templates/claude/claude-settings.json](../sandbox_templates/claude/claude-settings.json) — Bash/Read deny lists (curl, git push, pip install, secrets reads, etc.)
- [deny-destructive hook](deny-destructive-hook-plan.md) — PreToolUse hook blocking destructive commands (find -delete, dd of=, etc.)
- [sandbox_templates/claude/hooks/deny-destructive.sh](../sandbox_templates/claude/hooks/deny-destructive.sh) — hook implementation

## Proxy & Network

- [Squid internals](squid-internals.md) — cap model, tmpfs ownership, port restrictions, hot reload
- [Compose network IPAM](compose-network-ipam.md) — why `down` is needed for IPAM changes, DNS lockdown explained
- [Web-read broker (`webfetch`)](web-read-broker.md) — how the agent reads arbitrary pages through an allowlisted reader API (Tavily/TinyFish/Jina/Firecrawl) without widening egress; `scripts/webfetch.test.sh` locks it

## GPU & Docker

- [ARCHITECTURE.md](../ARCHITECTURE.md) (Substrate-specific notes) — NVIDIA Container Toolkit 1.18+ breakage on rootless Docker; why we pin 1.17.8-1; wsl-gpu overlay
- [sandbox-design-notes.md](sandbox-design-notes.md) — why container runs as root under rootless Docker (UID 0 = host UID 1000)
- [docker-bench-security-report.md](../reports/docker-bench-security-report.md) — Docker Bench for Security v1.6.0 results
- [Profile lifecycle → Local inference (Ollama sibling)](../.agents/skills/profile-lifecycle.md#local-inference-ollama-sibling) — per-profile, air-gapped Ollama on sandbox-internal; shared read-only model store; Claude Code's own backend switch

## Host Setup

Guides in [`host_setup/`](../host_setup/):

- [setup-rootless-docker-wsl-guide.md](../host_setup/setup-rootless-docker-wsl-guide.md) — rootless Docker on WSL2 Ubuntu 24.04
- [wsl_conf_update-guide.md](../host_setup/wsl_conf_update-guide.md) — /etc/wsl.conf settings
- [wsl_insert-guide.md](../host_setup/wsl_insert-guide.md) — /etc/wsl.conf insert settings (automount, network, interop)
- [ohmyzsh-host-setup-guide.md](../host_setup/ohmyzsh-host-setup-guide.md) — host-side oh-my-zsh

## CVE Management

- [.trivyignore.yaml](../.trivyignore.yaml) — accepted CVEs/misconfigs with `expired_at` for periodic re-check
- [`scripts/trivy-scan.sh`](../scripts/trivy-scan.sh) — host-side image/config/secret scan

## Scripts Reference

- [`scripts/profile.sh`](../scripts/profile.sh) — profile lifecycle (up, down, attach, auth, verify, audit, rebuild, clean)
- [`scripts/with-egress.sh`](../scripts/with-egress.sh) — temporarily widen the Squid allowlist for one install command, and the **only** route a dependency can take in ([ADR-0003](adr/0003-strict-egress-default.md)). Instrumented: OSV pre-flight, egress + filesystem diff per window, one JSON line to `~/.ai-sandbox/profiles/<p>/audit/depgate.jsonl`. Read back with `scripts/profile.sh <p> deps --history`
- [`scripts/depaudit.py`](../scripts/depaudit.py) — dependency-supply-chain posture scanner (stdlib-only, read-only; `posture` is offline, `pkg`/`deps` cross-check OSV for malicious-package records). Surfaced as `scripts/profile.sh <p> deps`
- [`scripts/run-ephemeral.sh`](../scripts/run-ephemeral.sh) — disposable one-shot containers
- [`scripts/init-profile-state.sh`](../scripts/init-profile-state.sh) — idempotent state bootstrap per profile
- [`scripts/sync-agent-notice.sh`](../scripts/sync-agent-notice.sh) — inject/refresh the managed sandbox-notice block into repo `AGENTS.md` / global `CLAUDE.md` (source: `sandbox_templates/common/agent-notice.md`)
- [`scripts/vendor-tools.sh`](../scripts/vendor-tools.sh) — the one door every vendored payload enters through (ADR-0014): reads the depot channel's `manifest.toml`, verifies **every** hash before copying **anything**, mirrors wheels/skills/plugin trees into `sandbox_templates/`, and records what it took in `VENDORED.lock`. `--check` adds the content half; `--permissions` reports the manifest's permission proposal against the settings template, report-only. Channel path from `$DEPOT_DIR` / `.depot-dir.local`. The myclickup payload stays **gitignored** — public repo, private tool — so the `Dockerfile` installs it conditionally and a clone without it still builds. Developer action; `just vendor-tools` / `just tools-check` / `just check-permissions`. Replaced `vendor-myclickup.sh` and `sync-skills-from-conventions.sh` (work/0016 Part B step 11)

## Operational

- [Debug recipes](debug-recipes.md) — routine commands for operating a profile
- [Local wheels](local-wheels.md) — per-profile `dist/` convention for local `.whl` files
- [sandbox_templates/common/db.env.template](../sandbox_templates/common/db.env.template) — database credentials template for postgres/mongo sibling containers

## Archive

Superseded or exploratory documents in [`_archive/`](_archive/):

- [PODMAN_MIGRATION_PLAN_gemini.md](_archive/PODMAN_MIGRATION_PLAN_gemini.md) — Podman migration proposal (not proceeding; see critique)
- [PODMAN_MIGRATION_PLAN_critique.md](_archive/PODMAN_MIGRATION_PLAN_critique.md) — analysis of why migration isn't worth it now (security delta ~0.5/10, WSL2 GPU blocker, idmapped mounts as future alternative)
- [gpt_suggestions_todo.md](_archive/gpt_suggestions_todo.md) — early-stage suggestions list
- [claude_internal_audit_wsl.md](_archive/claude_internal_audit_wsl.md) — manual audit prompt, superseded by tier-2 probes + tier-3 skill
- [agent_repo_conventions_advice.md](_archive/agent_repo_conventions_advice.md) — agent-native repo conventions proposal, implemented 2026-07-04 (AGENTS.md, .agents/skills/, sandbox_templates/)
- [IN_TRANSIT_agent-native-migration.md](_archive/IN_TRANSIT_agent-native-migration.md) — execution plan distilled from the above; all 8 steps landed 2026-07-04, archived from the repo root 2026-07-31
- [cross-repo-skill-pipeline-notes.md](_archive/cross-repo-skill-pipeline-notes.md) — `work/0005` execution log, archived 2026-08-18; its durable rule (*the detector belongs on the side that owns the stale copy; a skip is not a pass*) lives in AGENTS.md "Boundary monitors"
- [0004-deletion-is-a-human-step-plan.md](_archive/0004-deletion-is-a-human-step-plan.md) — the hook's third tier (`ask` / agy `force_ask`), merged 2026-08-24; carries the headless-ask measurements that AGENTS.md summarises
- [0006-manifest-keys-plan.md](_archive/0006-manifest-keys-plan.md) / [-notes.md](_archive/0006-manifest-keys-notes.md) — `manifest_flat` Option B (unrepresentable TOML values reported on stderr, never dropped), merged 2026-08-24
- [0007-genericise-public-identifiers-spec.md](_archive/0007-genericise-public-identifiers-spec.md) — the **searchable, not present-at-all** standard for client names in this public repo and the scope decision behind `scripts/private-names-check.sh`; merged 2026-08-24
- [0008-python-half-of-the-gates-plan.md](_archive/0008-python-half-of-the-gates-plan.md) — Gate 3 opt-out detection (P01 / G10p), the `UV_EXCLUDE_NEWER` window, `deps --vulns`; merged 2026-08-24
- [0010-antigravity-guardrails-spec.md](_archive/0010-antigravity-guardrails-spec.md) / [-plan.md](_archive/0010-antigravity-guardrails-plan.md) — the `agy` policy work whose durable record is [ADR-0006](adr/0006-antigravity-is-two-layer-like-claude.md); the plan carries the Phase 0 measurements
- [0011-policy-convergence-spec.md](_archive/0011-policy-convergence-spec.md) / [-plan.md](_archive/0011-policy-convergence-plan.md) — one policy convergence for every agent, durable record [ADR-0007](adr/0007-policy-templates-are-source-of-truth-for-every-agent.md); the plan carries the F1–F6 findings and the preserve-list decision
- [dependency-guardrails-plan.md](_archive/dependency-guardrails-plan.md) — the `work/0001` implementation plan; all phases (T00–T26) merged 2026-08-03, archived per its own exit rule. Superseded by [dependency-guardrails-handoff.md](dependency-guardrails-handoff.md), which carries what shipped, what remains, and the defect log
- [post_gpt5-6-sol_sandbox_break_ai_security_checklist_01.md](_archive/post_gpt5-6-sol_sandbox_break_ai_security_checklist_01.md) — third-party self-audit *prompt* (unverified, written without tree access). Same genre as `claude_internal_audit_wsl.md` and superseded the same way: tier-2 probes + the tier-3 audit skill. Its package/egress sections restate ADR-0003/0004 and the Gate 2/3 layers
- [post_gpt5-6-sol_sandbox_break_ai_security_checklist_02.md](_archive/post_gpt5-6-sol_sandbox_break_ai_security_checklist_02.md) — terser sibling of the above. Its five **host-trust** sections (D/E/F/I/J) were the only genuinely new material in the incoming set and are folded into [RFC-04 §8](_archive/04-portable-guardrails-outside-sandbox.md); the rest restated existing controls
- [securing_agentic_coding_environments_gemini_deep_research.md](_archive/securing_agentic_coding_environments_gemini_deep_research.md) — outside model's architecture research (MicroVMs/Firecracker, SPIFFE, eBPF Falco/Tetragon). Not proceeding, per the `PODMAN_MIGRATION_PLAN_gemini.md` precedent: these are enterprise-fleet controls for a single workstation, and its recommendation 5 (rootless Docker, Colima on macOS, VS Code socket hygiene) is already the shipped posture. Its one unexamined idea — a shared package cache as the high-value target — was extracted to the handoff's §6 watch item before archiving
- [0002-host-side-skill-slot-plan.md](_archive/0002-host-side-skill-slot-plan.md) — closed 2026-08-24 without implementation (host-side planning stays container-only); folder deleted in `151cebf`, restored 2026-08-25 to `docs/_archive/` per [ADR-0010](adr/0010-one-proposal-home-close-the-rfc-tier.md)'s tightened exit rule
- **`docs/rfcs/` (closed 2026-08-25, [ADR-0010](adr/0010-one-proposal-home-close-the-rfc-tier.md))** — all five files kept, unrenumbered:
  [DEPENDENCY_GUARDRAILS.md](_archive/DEPENDENCY_GUARDRAILS.md) (slopsquatting threat + agent behavioural rules — shipped, phase 0),
  [01-posture-scanner-plan.md](_archive/01-posture-scanner-plan.md) (`depaudit` — built in part as `scripts/depaudit.py`),
  [02-layered-gates-plan.md](_archive/02-layered-gates-plan.md) (`depgate`, five-gate model — rejected as a system → ADR-0002; the gate model is retained as vocabulary),
  [04-portable-guardrails-outside-sandbox.md](_archive/04-portable-guardrails-outside-sandbox.md) (host-side subset — partially applied, unowned),
  [05-deps-repo-filter.md](_archive/05-deps-repo-filter.md) (`--repo` filter for `profile.sh deps` — **Rejected** with the tier, draft was never implemented),
  [TEMPLATE.md](_archive/TEMPLATE.md) (the RFC status-header template)
