# 0027 — An admin profile: the deployment tier gets a container of its own

**Status: Draft** — opened 2026-09-10; D2 accepted the same day, D1 defined (§8) after the three-way re-vendor
correspondence of 2026-09-09/10 (myclickup 0.7.0, myconv 0.8.0, paperbridge
0.2.1 — `docs/handoff-reply-*.md`). **ADR candidate**: it adds a profile
*class* with a different posture, which touches the security boundary.

**Cross-refs:** [ADR-0003](../../docs/adr/0003-strict-egress-default.md)
(egress stays gated), [ADR-0007](../../docs/adr/0007-policy-templates-are-source-of-truth-for-every-agent.md)
(policy converges on `up` — the self-modification hazard in §6),
[ADR-0008](../../docs/adr/0008-deletion-is-a-human-step.md) (kept in full),
depot `AGENTS.md` "Crossing to the sandbox" (the rule this item revises),
[0026](../0026-vendor-paperbridge/spec.md) (the last loop this would have shortened).

---

## 1. The problem, stated precisely

The depot channel's rule today (its `AGENTS.md`): member repos are reachable from
a container; `windows-ai-sandbox` "lives on the host and **no container can reach
it**", so anything touching a vendored wheel, a skill text, the image or the
allowlist is written down and **human-ferried**.

What that costs was measured across the three re-vendors above: three
handoffs written by depot-side agents, three tracked replies written here, one
correction to a reply, one in-place correction to a handoff, and a human
starting a session on each side for each turn. The bytes that moved were a
wheel, a skill tree and a lock file. The *operation* — `vendor-tools.sh vendor`,
`--check`, pin regeneration, `test-offline` — is mechanical and offline.

Two findings reframe the ask:

1. **The friction is not the mount.** The host-side agent already reads and
   writes depot by absolute path (`.depot-dir.local`, `$DEPOT_DIR`); replies
   land directly in member `inbox/`. What is missing is one agent that can see
   *both* trees and act on the sandbox side.
2. **The agent being replaced is not a sandboxed one.** The sandbox side of every
   exchange was a host session: no egress gate, no PreToolUse hook, the rootless
   docker socket in reach, and every `~/.ai-sandbox/profiles/*/secrets.env`
   readable. Any container with Squid in front of it is a *tightening* of the
   current deployment-tier practice, not a loosening of the sandbox.

## 2. Options considered

| # | Option | Verdict |
|---|---|---|
| A | Mount this repo **read-only** into the `nranthony` profile (per-profile overlay, same shape as `--expose-dev`) | Cheap, no boundary cost (repo is public). Removes only the "what did you consume" half of the loop. Not sufficient alone; subsumed by C |
| B | Temporary **read-write** mapping into an existing profile | **Rejected.** That profile's own policy converges from the tree it would be editing (ADR-0007): the agent edits its own guardrails from inside them. And it still cannot act — `up`/`build`/`verify` need the docker socket — so the human step stays and the separation is lost |
| C | A dedicated **admin profile**: its own policy template, the sandbox repo and depot both under `/workspace`, Squid still in front, **no docker socket** | **Recommended.** §3–§7 |
| D | Shrink the *protocol* rather than the topology: handoff contract = a `RELEASES.md` line + `tools-check` going red | Independent of A–C and worth doing regardless. Named in §9, not owned here |

## 3. What the admin profile is

One more profile through `scripts/profile.sh` (golden rule 1 — never a
side-channel `docker run`), differing from a workload profile in exactly four
ways, all carried by an overlay and a template:

| Aspect | Workload profile | Admin profile |
|---|---|---|
| `/workspace` | `~/repo/<p>/` | `~/repo/sandbox/` (this repo's parent) **plus** the depot channel root mounted at `/workspace/depot` — a predefined list, not `~/repo` |
| Pointer files | `.depot-dir.local` etc. hold host absolute paths | overridden by env: `DEPOT_DIR=/workspace/depot`, `MYCLICKUP_DIR`, `CONVENTIONS_DIR`, `PAPERBRIDGE_DIR` likewise. **The override precedence already exists** (`vendor-tools.sh:84`), so the same gitignored files serve both sides unchanged |
| Claude policy | `sandbox_templates/claude/claude-settings.json` | `sandbox_templates/claude-admin/claude-settings.json` — §4 |
| Docker socket | absent | **absent** — §5 |

Everything else is identical: image, seccomp, cap_drop, tmpfs, Squid, the
hook engine, per-profile state under `~/.ai-sandbox/profiles/admin/`.

**Compose wiring.** The base compose stays substrate-neutral (golden rule 2), so
the workspace remap and the env overrides live in a per-profile overlay
`docker-compose.admin.yml`, layered by `profile.sh` the way `--expose-dev`
layers `docker-compose.<p>.expose-dev.yml` (`parse_flags`, `add_overlay`). The
selection signal is a decision gate (§8 D1): a fixed profile name, or a marker
in the profile state dir.

**What it can do inside, all offline by design:** every suite `just test-offline`
runs (ten, none needs docker), `vendor-tools.sh vendor|--check`, constraints
regeneration, `depaudit.py`, the handoff/reply docs, `git commit`, and — the
one new capability — `git push` to the listed repos.

## 4. The admin policy — recommended plan

Start from the workload template and change as little as possible. The
principle: **relax only what the deployment loop needs; keep every rule whose
reason is "the agent should not do this unattended" rather than "the agent
should not reach the network".**

### 4.1 Moves from `deny` to `allow`

| Rule | Why the workload denies it | Why admin allows it |
|---|---|---|
| `Bash(git push:*)` | egress is the boundary; push is unattended publication | the whole point. github.com is **already open** in egress (accepted exception, `allowed_domains.txt` ~L268), so this is a policy change only, not an egress change |
| `Bash(git fetch:*)`, `Bash(git pull:*)` | same | reading the remote is needed to push safely; same transport as push |

### 4.2 Stays in `deny`

| Rule | Reason it survives |
|---|---|
| `Bash(gh:*)`, `Bash(glab:*)` | PR creation and issue writes are outward-facing and irreversible; the human opens PRs. Revisit only if the loop proves to need it (D3) |
| `Bash(git clone:*)`, `Bash(git submodule:*)` | the repo list is *predefined* by the mounts; cloning inside defeats that |
| `Bash(git config:*)` | the credential-helper scrub is load-bearing (audit Finding B/C); the token route in §4.4 needs no config write |
| every installer / fetch-and-run / interpreter-wrapper prefix | unchanged — the admin profile edits the gates, it does not need to pass through them. Dependency work still goes through `with-egress.sh` from the host |
| `curl`, `wget`, `ssh`, `scp`, `rsync`, `socat`, `nc` | unchanged |
| `myclickup delete`, `paperbridge delete|rm`, `bd dolt|init|setup` | unchanged |

### 4.3 Stays in `ask`, and the hook stays

The deletion tiers (ADR-0008) and the `deny-destructive` hook run unchanged —
same engine, same dialect, same three tiers. An admin profile that could
`rm -rf` this tree is worse than the human step it replaces.

### 4.4 The push credential

A **fine-grained PAT** (or per-repo deploy keys) whose repository list *is* the
predefined mount list, expiring, contents-write only, placed in
`~/.ai-sandbox/profiles/admin/secrets.env` as `GH_TOKEN` — read at container
create like every other key there. Git consumes it through `GIT_ASKPASS`
pointing at a tiny script in the image that echoes the env var, so **no
`credential.helper` is written** and the scrub stays untouched. GitHub then
enforces the repo list; prose does not.

### 4.5 Twin for antigravity

`agent-policy.test.sh` diffs the claude and antigravity lists exactly, both
directions, no exception list. Either the admin profile ships an
`antigravity-admin-settings.json` twin kept in the same lock, or it declares
"claude only" and the descriptor table records that. D2.

## 5. What stays human, and why that is a feature

- **`profile.sh <p> up | build | verify | audit` on every profile, including
  admin.** They need the docker socket, and the socket does not go in: rootless
  socket = host UID 1000 = "mount `$HOME` anywhere". With it the admin container
  is the host with extra steps and the Squid gate is theatre. Without it, the
  agent that **changed** the boundary is never the agent that **certifies** it —
  a review gate this repo currently has only informally.
- **Reading the diff before `up` on a workload profile.** ADR-0007 means an edit
  to `sandbox_templates/claude/` is live policy on the next `up`. The admin
  profile can *write* that edit; only the human *applies* it.
- **Live spot-checks in a workload profile** (the four paperbridge probes still
  owed from 0026) — unchanged, they need that profile's container.

## 6. The risk to say out loud

Depot content — member repos, skill texts, handoffs — is written by other
agents. Prompt injection there, steering an edit to `seccomp.json`, the hook,
or `allowed_domains.txt`, is the one attack an admin profile invites. Today the
same content reaches an unsandboxed host session, so the exposure **shrinks**;
but it should be named and mitigated explicitly:

1. the admin profile never converges into another profile (it has no socket);
2. the human reads the diff before `up` (§5);
3. `verify`/`audit` run host-side, from the tree, after the diff — never from
   inside the admin container;
4. the admin profile's **own** policy converges from the tree it edits. That is
   the ADR-0007 self-modification hazard from option B, narrowed: the effect is
   deferred to the human's next `up admin`, and the `settings.discarded.json`
   capture + tier-1 policy-sync check make a drifted template visible. Whether
   that is enough, or the admin template should converge from a copy outside
   `/workspace`, is D4.

## 7. Verification this item must add

- `profile.sh` overlay selection: `agent-policy.test.sh` gains the admin
  descriptor row(s) and asserts the admin list is the workload list **plus
  exactly the §4.1 set** — a generated diff, not a second hand-maintained list
  (the drift lesson from `pnpm dlx` and its siblings).
- `verify` tier 1 on the admin profile: asserts no docker socket mount, asserts
  `git config --global -l` carries no `credential.helper`, asserts the four
  `*_DIR` env overrides resolve inside `/workspace`.
- `vendor-tools.sh --check` runs green from inside the admin container against
  `/workspace/depot` — the proof that the env-override route works end to end.
- `test-offline` green inside the container (the `private-names-check` reads
  its gitignored `.private-names.local` from the bind mount, so it is real, not
  `[SKIP]`).

## 8. Decision gates

| # | Question | Recommendation |
|---|---|---|
| D1 | How does `profile.sh` know a profile is admin-class — fixed name `admin`, or a marker file in the profile's **state dir** (`~/.ai-sandbox/profiles/<p>/`, the host-side directory that already holds `claude-home/`, `config/`, `secrets.env`, `backend.env`)? | **Marker file, `profile.class` containing `admin`, written once by `init-profile-state.sh`.** Names are already client names on this public repo; a class marker lets a second admin-class profile exist without editing `profile.sh`; and the state dir sits outside every bind mount, so nothing inside a container can promote itself |
| D2 | Antigravity twin, or claude-only? | **Accepted 2026-09-10: claude-only for the first cut**, recorded in the descriptor table and asserted by the suite; add the twin when `agy` is used from the admin profile |
| D3 | `gh` allowed? | No. PRs are the human's; revisit with evidence from the first three loops |
| D4 | Admin policy converges from `/workspace/...` (self-edit hazard, deferred) or from a host-side copy outside the mount? | Converge from the tree, with the existing capture + tier-1 check as the detector. A second source of truth for the same template is the ADR-0005/0007 anti-pattern |
| D5 | Token form: fine-grained PAT vs per-repo deploy keys? | Fine-grained PAT, 90-day expiry, contents:write on the listed repos only. Deploy keys are per-repo SSH, and `ssh` stays denied |

## 9. Out of scope, named so it is not lost

- **Option D — the protocol.** Shrinking the handoff contract to "a RELEASES.md
  line plus a red `tools-check`" is a depot-side convention change and belongs
  in agentic-conventions. It cuts the paperwork whichever topology ships.
- **The revision to depot `AGENTS.md`** ("no container can reach it" becomes
  "only the admin profile can, and it cannot apply") — written once this ships,
  ferried the last time by hand.

## 10. Exit rule

Merges when: the admin profile comes up through `profile.sh`, `test-offline`
and `vendor-tools.sh --check` are green from inside it, one real re-vendor loop
has been run end to end with no ferried document, the §7 assertions are in the
suites, and the ADR is filed. Then this folder archives to `docs/_archive/`.
