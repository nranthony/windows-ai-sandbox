# 0020 — `genmedia` CLI: fal.ai media tooling inside the sandbox

**Status: Draft** — four decisions taken 2026-08-30 (§6), three still open (§7).

**Touches:** `Dockerfile` (the binary), `proxy/allowed_domains.txt` (the `[fal]`
block), `sandbox_templates/common/secrets.env.template` (done), and
`sandbox_templates/claude/hooks/deny-destructive.sh` (the ask rule). Per AGENTS.md
that means the commit message states the security impact, tier-1 `verify` passes,
tier-2 `audit` runs, and `dockerfile-order.test.sh` (8/8),
`deny-destructive.test.sh` (207/207) and `with-egress.test.sh` (82/82) run.

**Supersedes this spec's first revision.** That version triaged
`work/plans/fal-ai-related-host-tasks.md`, a derived 43-item checklist that names
the CLI exactly once — "the CLI", item 1.1, no antecedent. The source it derives
from is `~/repo/fluidmomenta/website/work/plans/fal-ai-genmedia-collated-misc.md`
(22KB, a **different repo's workspace**), and that one names `genmedia` as the
execution path everything else hangs off. The first revision was a sound triage
aimed one level too low. The triage tables (§4, §5) survive; the findings and
decisions are rewritten.

**Measured 2026-08-30** from `fal-ai-community/genmedia-cli` at v0.7.0 and the
live containers. Nothing was installed; no container was modified.

---

## 1. What `genmedia` is

The agent-first CLI for fal.ai — discover endpoints, inspect schemas, submit,
poll, upload inputs, download outputs, check pricing, search docs. Distinct from
the `fal` CLI, which deploys fal *applications*. Command surface at v0.7.0
(`src/commands/`): `models`, `schema`, `run`, `status`, `upload`, `pricing`,
`docs`, `init`, `skills/`, `setup`, `gallery/`, `assets/`, `update`, `version`.

The fal community skills repo (`fal-ai-community/skills`, ~18 skills) is a
knowledge layer on top: every skill executes through `genmedia` rather than
wrapping fal's HTTP API. So the CLI is the thing to provision; the skills are a
separate, lighter decision (§6.2).

### 1.1 Measured facts about the artifact

| Fact | Value | Why it matters |
|---|---|---|
| Language / build | TypeScript, `bun build --compile --minify --bytecode` | A **Bun single-file executable**. Bun is embedded, so it does NOT need `bun` on `PATH` and does not reopen work/0009's parked runtime question — but the bytes are a Bun runtime and should be described as such, not as "a Node CLI". |
| Linux x64 asset | 106,777,922 bytes | ~107MB added to the image. Not free, and worth stating before a rebuild. |
| Licence | MIT | No vendoring-licence question (source item 5.4). |
| Latest release | **v0.7.0, 2026-05-29** | 15 releases in six weeks (2026-04-16 → 05-29), then **three months of silence**. `pushed_at` equals the release date. The opposite risk from 0019's comfyui-mcp (454 releases/6mo): not churn, possible abandonment. |
| Checksums | `checksums.txt` per release; linux-x64 `72a39bd3…d760fd34` | Pinning is trivial and the upstream publishes the hash itself. |
| npm | `@fal-ai/genmedia-cli`, `bin` → `./dist/genmedia` | An npm route exists and would fall under Gate 2. Whether the tarball ships the prebuilt binary is **unverified** (§8). |
| Runtime dependency | `@fal-ai/client ^1.10.0` | Independent confirmation that `rest.fal.ai` is the storage/polling host — the same constant that justified commit `7d85f51`, reached from a second direction. |
| Telemetry | `posthog-node`, `__POSTHOG_KEY__` baked at build; `src/lib/analytics.ts:10` → `https://us.i.posthog.com` | The CLI phones home by construction. That host is **not allowlisted** and will 403. §5.4. |
| Platform API | `src/lib/api.ts:5` → `https://api.fal.ai/v1` | Why the 2026-08-29 probe saw `api.fal.ai`. |
| Key page | `src/lib/api.ts:15` → `https://fal.ai/dashboard/keys` | The exact URL for creating the key the secrets template asks for. |
| `skills install` target | `src/lib/skills-install.ts:29` → `.claude/skills` under `cwd` | **Workspace-level, not `~/.claude/skills`.** This is what makes §6.2 safe — see there. |

## 2. Goal

Give a media workspace a working, gated, cost-aware fal.ai path:

1. `genmedia` **in the image** at a pinned version, verified by upstream hash.
2. `FAL_KEY` from `secrets.env` — **environment only, never argv**.
3. `[fal]` staying gated; egress opened per command by `with-egress.sh --with fal`.
4. A paid submit reaching the **ask tier**, so spending money is a human step.
5. `ffmpeg` present, because the pipeline this serves cannot complete without it.

## 3. Where this collides with the sandbox

Four collisions, none of which either source note could see.

### 3.1 The documented install is pipe-to-shell, and is blocked here by design

```
curl https://genmedia.sh/install -fsS | bash
```

That is the exact fetch-and-run form `sandbox_templates/common/agent-notice.md`
names and `permissions.deny` blocks — `agent-notice.test.sh` asserts every form
named in the notice has a real deny entry behind it. `genmedia.sh` is also not in
the allowlist. So the vendor's install path is unusable inside a profile, and that
is correct behaviour, not a defect to work around.

`install.sh` is better than it looks, though, and its two good properties transfer:
it honours **`GENMEDIA_VERSION`** (so the upstream itself supports pinning) and it
verifies `checksums.txt` before installing. §6.1 keeps both and drops the pipe.

### 3.2 `genmedia setup --api-key "$FAL_KEY"` puts the key on argv — RESOLVED

The collated note's non-interactive bootstrap passes the key as an argument. That
breaks the rule written into the secrets template in `7d85f51` and locked for the
web-read broker by `webfetch.test.sh` (90/90): keys travel in the environment and
in headers, never argv, because argv is visible in `ps` and lands verbatim in the
Bash-tool transcript.

**Closed from source, no measurement needed.** `getApiKey()` (`src/lib/api.ts:7`)
is `process.env.FAL_KEY ?? loadConfig().apiKey` — the environment is read FIRST,
ahead of the stored config. So `genmedia setup` never needs running and
`--api-key` is never typed. It also fixes the keyless boundary: everything routed
through `platformHeaders()` or `configureSDK()` — `models`, `schema`, `pricing`,
`run`, `status`, `upload` — hard-errors without the key, while `version`,
`--help` and the skills commands do not.

### 3.3 genmedia self-updates in the BACKGROUND — worse than a manual command

Not just `src/commands/update.ts`. `src/index.ts:47` carries an internal
`__update-check` entrypoint "used by the background auto-update subprocess", and
`maybeTriggerBackgroundUpdate()` (`src/lib/updater.ts:120`) `Bun.spawn`s a
detached child — `stdio` all ignored, `unref()`ed — which reads
`api.github.com/repos/fal-ai-community/genmedia-cli/releases/latest` and stages a
binary swap (`preSwapPendingUpdate`, `updater.ts:84`).

**`api.github.com` is allowlisted**, as an accepted-open residual of the `[git]`
block. So without intervention a baked, hash-verified, version-pinned binary is
pinned in name only, and the drift would be invisible to `check-upstreams`. The
binary download would then fail at the redirect — `objects.githubusercontent.com`
and `release-assets.githubusercontent.com` are commented out — leaving an hourly
retry loop rather than a successful swap, which is a worse failure than either
outcome because it is quiet.

Two early returns reduce but do not remove the exposure: it skips when stdout is
not a TTY and when `--json` is present (`updater.ts:123-124`), so an agent using
the documented `--json` mode would rarely trigger it. `profile.sh <p> attach` is
a TTY, and "rarely" is not a control. Resolved by §6.5.

### 3.4 The skills bundle is 0019 §2.3 again

`genmedia init` installs a default bundle; the community repo carries ~18 skills.
0019 met the same shape as "42 skills, 4 agents and 3 hooks nobody asked for".
Resolved by §6.2, differently from how 0019 resolves it.

## 4. Still answered by existing machinery — 15 items

The first revision's table holds, with two entries moved out by the measurements
above. Unchanged and still answered by an existing ADR, script or test:

`1.4` allowlist model ([ADR-0003](../../docs/adr/0003-strict-egress-default.md): one
host-side file, directory-mounted, shared by every profile; the dashboard rewrites
it wholesale so check `git diff` after using it) · `2.1` injection point (optional
`env_file`, `chmod 600`, outside the repo tree, never baked) · `2.4` rotation
mechanics (`env_file` is read only at container CREATE, so rotation costs
`profile.sh <p> recreate`) · `2.6` visibility (both — §5.3) · `4.2` pinning and
rebuild cadence · `4.4` install-location survival (the state-placement table;
`/tmp` is `noexec`) · `4.6` discovery (`verify` prints presence lines) · `5.2`
no symlinks, convergence mirrors by copy, `profile-skills.test.sh` 24/24 · `5.4`
licensing (MIT, §1.1) · `5.5` corrected-skill update path · `5.6` portable vs
repo-specific (`sandbox_templates/skills/web-read/SKILL.md` is the pattern) ·
`6.2` write once, swap invocation ([ADR-0011](../../docs/adr/0011-web-read-backends-are-peers-with-no-default.md))
· `6.4` unreachable is the resting state under default-deny · `7.5` clean
degradation · `8.1` one operator owns image, allowlist and secret store.

**Moved OUT of "answered" by the genmedia measurements:**

- **`1.6` update/telemetry endpoints.** Was "blocked by construction, no decision
  needed". There is now a named host (`us.i.posthog.com`) and a real question about
  what a blocked CONNECT does to the CLI. → §5.4.
- **`4.3` self-update disabled?** Was "repo posture is already no-self-update".
  `genmedia update` exists and must be actively neutralised. → §3.3, §7.2.

## 5. Not applicable — 4 items

`2.2` per-session / per-tenant key scoping (the unit is the profile; three
profiles, one operator) · `5.4`'s vendoring-licence half (MIT, and §6.2 vendors
nothing) · `6.3` fallback provisioned per-fleet · `8.1`'s separate-parties premise.

## 6. DECISIONS TAKEN — 2026-08-30

### 6.1 Install: measure the artifact, then bake a pinned release into the image

Not `curl | bash`, not npm. The `Dockerfile` fetches
`https://github.com/fal-ai-community/genmedia-cli/releases/download/v<pin>/genmedia-linux-x64`,
verifies it against the published `checksums.txt` hash **before** it is made
executable, and installs it to a durable path. Rationale: the upstream publishes
per-release hashes, so this repo's normal posture (pin + verify + a detector in
`just check-upstreams`) applies with no new machinery. Build-time fetch does not
traverse Squid, so no allowlist entry is needed for the download host — the
`[git]` block's `objects.githubusercontent.com` and
`release-assets.githubusercontent.com` lines stay commented.

**Implemented 2026-08-30**, modelled line-for-line on the existing `just` block
(`Dockerfile:331-357`), which already does exactly this: `ARG` for the version,
fetch the asset and the checksum file from the release, `awk` the expected hash,
hard-fail when the checksum file has no line for this asset, `sha256sum -c -`,
then install. genmedia's `checksums.txt` is the same two-column format, so the
only differences are `install -m 0755` instead of a tar extract and an arch case
mapping `amd64→genmedia-linux-x64` / `arm64→genmedia-linux-arm64`.

The hash is verified **before** the file is made executable, and an absent
checksum entry fails the build rather than reading as a pass.

Layer placement: above the AI-CLI refresh cache-buster, so `build --refresh-ai`
does not re-download 107MB. It is a single static binary depending on neither
Gate 2 nor Gate 3, so it sits with the other pinned tool installs rather than in
the quarantined tail. `dockerfile-order.test.sh` passes 8/8 — note that its
anchors are grepped over the whole file including comments, so prose in a new
block must not repeat an anchor string verbatim (this was caught, not theorised).

### 6.2 Skills: per-workspace `genmedia init`, not central convergence

Rejected: vendoring a subset into `sandbox_templates/skills/`. Chosen: each media
workspace runs `genmedia init` / `genmedia skills install <name>` and commits the
result to **its own** repo.

This is safe here for a specific measured reason: `skills-install.ts:29` targets
`.claude/skills` **relative to `cwd`**, i.e. the workspace. It never touches
`claude-home/skills/`, so [ADR-0005](../../docs/adr/0005-skill-templates-are-source-of-truth.md)'s
mirror semantics are not engaged and nothing is at risk of being pruned.

**The accepted residual, stated plainly:** source item 5.3 asked whether a
registry-installed bundle is reviewed before it lands. Under this decision the
answer is **no** — `genmedia skills install` writes agent-executable instruction
files into a workspace without passing `vendor-tools.sh`. That is a deliberate
trade for keeping non-media profiles clean and matching the vendor's model, and it
should be recorded as a residual, not quietly enjoyed as a simplification.

### 6.3 A paid submit is an `ask`

`genmedia run` (and any submit form D1 observes) gets a rule in
`deny-destructive.sh` landing on the **ask** tier. Both dialects, because the
postures are deliberately opposite: claude emits `permissionDecision:"ask"`,
`agy` emits `decision:"force_ask"` — a plain `ask` under `agy` caches as a
permanent Always-Allow grant, which here would mean "approve one image, then spend
freely forever". Suite grows past 207/207.

This is the enforcement half of the collated note's contract ("ask for approval
before executing any paid batch"). The note's other controls — ≤4 concurrent jobs,
budget-threshold stop, never blind-retry a paid request — stay documentation, and
§7.3 is where that line gets drawn.

### 6.4 `ffmpeg` is required, not optional

The pipeline this serves normalises each clip, concatenates from an explicit
ordered edit list, and validates duration/resolution/fps/codec with `ffprobe`
before promoting an edit to final. **Measured: no `ffmpeg` in the `Dockerfile` and
none on `PATH` in `ai-sandbox-nranthony`.** Without it, generated video arrives as
bytes nothing in the container can transcode, inspect or thumbnail. **Implemented 2026-08-30**: its own apt
layer beside genmedia, for the same reason `libgl1` is baked — `apt-get` cannot
run at container runtime here, since `cap_drop ALL` + `no_new_privs` stops it
acquiring its locks, so the alternative is a `with-egress.sh --with apt` window on
every recreate. Both `ffmpeg` and `ffprobe` are smoke-checked in-layer, so a base
image that drops either fails the build rather than a video job months later.

### 6.5 `GENMEDIA_NO_UPDATE=1` — baked into the image

Promoted from an open question once the opt-out was found in source. The
background updater checks this variable at `updater.ts:122`, **before** any
network call, so nothing is spawned and nothing is staged. Set as a `Dockerfile`
`ENV` beside the binary rather than in `secrets.env`: it is not a secret, and it
must hold for every profile, not only the ones with a key.

Chosen over a `deny-destructive.sh` rule on `genmedia update`, which was the
first revision's plan: a hook rule catches the command the operator types and
misses the detached subprocess entirely — it would have looked like a control
while the real path stayed open. A hook rule on the explicit command is still
reasonable belt-and-braces, but it is not the load-bearing half.

### 6.6 `GENMEDIA_NO_ANALYTICS=1` — and `us.i.posthog.com` stays OUT of the allowlist

Also promoted from an open question. `isOptedOut()` (`analytics.ts:34`) is checked
**before** `await import("posthog-node")`, so with the variable set the client is
never constructed and no connection is ever attempted — not blocked-and-swallowed,
never tried.

The CLI is fail-safe without it (the whole init sits in `try {} catch {}` under
the comment "Analytics must never break the CLI"), so this is not about
correctness. It is about latency and about not being talked into an allowlist
entry later: the client is built `flushAt: 1, flushInterval: 0`, one flush per
event, so leaving it enabled means a connection attempt per command against a
host that 403s. The wrong fix for that symptom is allowlisting an analytics host.
The PostHog key is compiled into the binary (`--define __POSTHOG_KEY__`), so it
cannot be disabled by simply not configuring one.

## 7. STILL OPEN — one item

### 7.1 The key itself

**Profile chosen 2026-08-30: `fluidmomenta`**, to start. It is where the ComfyUI
work from 0016 lives and where the 2026-08-29 reachability probe came from. The
other two profiles get the image (it is shared) but no key, which is the honest
answer to source item 2.8: the tooling is present everywhere, the capability is
not.

One key or three stays open until there is a second profile to argue about.
Per-profile keys are the only route to provider-side attribution (§5.4); the cost
is a `recreate` per rotation.

*Blocking D1 and nothing else.* Every step in §8 up to D1 proceeds without it. The
key is placed by the operator into
`~/.ai-sandbox/profiles/fluidmomenta/secrets.env` — never read, printed or
committed here. Because `env_file` is read only at container CREATE and the image
rebuild forces a recreate anyway, placing it before the rebuild costs nothing;
placing it after costs one extra `profile.sh fluidmomenta recreate`.

## 8. Steps

**D1 — the measurement run.** Blocked on §7.1 only. Vehicle corrected from the
first revision: **not** `run-ephemeral.sh` — that script builds its `docker run`
by hand and never loads `secrets.env` (`scripts/run-ephemeral.sh:88-105`), so a
scratch container has no key. Use:

```
scripts/with-egress.sh <profile> --with fal -- 'genmedia ...'
```

which `docker exec`s the **persistent** agent container (`with-egress.sh:949`) —
that one has the `env_file` — opens `[fal]` for the command, restores the
allowlist verbatim on exit, and writes the install audit log. No new capture
tooling is needed either: `egress_hosts()` (`with-egress.sh:826-847`) already
reads `access.log` for the window and classifies allowed/denied per host, carrying
the millisecond-boundary fix that once made a real install log report zero egress.

Re-gate `[fal]` first. It is uncommented in the working tree, and `--with` on an
already-open block is a documented safe no-op (`with-egress.sh:60`) — the run
would exercise none of the gate and report nothing newly opened.

What D1 must answer, in order:

1. The full host census on submit → poll → download, from `egress_hosts()`.
   **Delete** any line in `[fal]` the run never produces — the block's own rule.
2. Do download redirects stay inside `.fal.media`?
3. Does `genmedia init` need egress, or are the skills bundled in the binary?
   (`skills-install.ts` shows no registry fetch — unresolved, §10.)
4. The shape of a denied-host failure and an expired-key failure, deliberately.
5. `genmedia status <endpoint> <request-id> --result --download` after the
   submitting session is killed — the orphan-recovery path (§10 caveat).
Steps 1–2 of the first revision are gone: the env-vs-`setup` question closed from
source (§3.2), and the telemetry question closed by §6.6. The `noexec /tmp`
question closed by measurement — see §8.1.

### 8.1 Done 2026-08-30 — the image half

`Dockerfile`: §6.1 pinned binary, §6.4 ffmpeg, §6.5/§6.6 the two ENV opt-outs.
`dockerfile-order.test.sh` 8/8. Verified against the built image, not the build
log:

| Check | Result |
|---|---|
| binary present | `/usr/local/bin/genmedia` |
| **hash** | `72a39bd3…d760fd34` — byte-identical to upstream `checksums.txt` for `genmedia-linux-x64` |
| opt-outs live | `GENMEDIA_NO_ANALYTICS=1`, `GENMEDIA_NO_UPDATE=1` |
| media tooling | `ffmpeg` + `ffprobe` 6.1.1-3ubuntu5 |
| runs keyless | `genmedia version` → `{"version":"0.7.0","update_available":null}` — `update_available: null` is the updater confirming it did not run |
| **under full hardening** | seccomp + `cap_drop ALL` + `no_new_privs` + `noexec /tmp`: `version`, `--help` and `models` all execute |
| **`noexec /tmp`** | not an issue — the compiled Bun executable does not extract to `/tmp`, unlike the `just` shebang case. Measured, not assumed. |
| keyless boundary | `genmedia models` returns a clean JSON error naming `FAL_KEY` and attempts **no** request — matching `getApiKey()` erroring ahead of the call |

**The running containers are still on the old image.** `build` does not recreate,
and no `--recreate-running` was passed. `fluidmomenta` picks this up on its next
`scripts/profile.sh fluidmomenta recreate` — the same recreate that reads a newly
placed `FAL_KEY` (§7.1), so one action serves both.

Two incidental findings about `run-ephemeral.sh`, both of which disqualify it as
D1's vehicle and neither of which is a defect on its own terms: it has no
`--env-file` (`:88-105`), and it hardcodes `docker run --rm -it` (`:75`), so it
cannot be driven non-interactively at all.

**Then, in order:** `check-upstreams` detector for the pinned version →
`deny-destructive.sh` ask rule for a paid submit (§6.3) → key placement (§7.1) →
D1 → allowlist correction from D1's census → docs.

## 9. Non-goals

- Reopening 0016's local ComfyUI. fal is for what the local GPU cannot do; this
  item does not make it the default path for image work.
- Any always-on egress. `[fal]` stays gated whatever else lands.
- Vendoring the community skills into this repo (§6.2 decided against).
- Baking a key anywhere.

## 10. Unverified — do not present these as fact

- **Whether the `@fal-ai/genmedia-cli` npm tarball ships the prebuilt binary** or
  requires a Bun build. Only matters if §6.1's GitHub-release route fails.
- **Where `genmedia skills install` fetches from.** `skills-install.ts` shows no
  URL constant; the content may be bundled in the 106MB binary. If it is, `init`
  needs no egress at all — a materially better answer than assuming a registry
  host. Not resolved; D1 step 5.
- **Whether the orphan-recovery path actually works.** `--async` + persisted
  request ID + `genmedia status … --result --download` is what the collated note
  prescribes and the command surface supports it, but no one here has killed a
  session mid-job and recovered the artifact.
- **fal's key model** — scoping, per-key spend caps, revocation latency. Unchecked.
  If no enforceable cap exists provider-side, §6.3's ask tier and the gated block
  are the only real bounds.
- **Whether v0.7.0 has an update opt-out or a telemetry opt-out env var.** §7.2, §7.3.
- **Whether the project is still maintained.** Three months quiet after six weeks
  of rapid releases. Relevant to §6.1's pin: a stale pin on an abandoned project is
  fine; a stale pin on an active one is drift.
