# 0020 — fal.ai media tooling: 17 of the 43 questions are already answered here

**Status: Draft** — five decision gates (§6) go to the owner before implementing.

**Touches, if implemented:** `proxy/allowed_domains.txt` (the `[fal]` block),
`sandbox_templates/common/secrets.env.template`, and — depending on D5 — the
`Dockerfile` and `sandbox_templates/skills/`. Per AGENTS.md that means the commit
message states the security impact, tier-1 `verify` passes, tier-2 `audit` runs,
and the suites behind whichever surface is touched run
(`with-egress.test.sh` for allowlist parsing, `webfetch.test.sh` for the secrets
template, `dockerfile-order.test.sh` for a baked payload).

**Follows 0016 and sits beside 0019.** 0016 put ComfyUI *inside* the sandbox with
zero always-on egress. 0019 asks whether the agent gets tools against it. This one
asks whether the agent gets tools against a **paid, off-boundary GPU** instead —
which is a different question, because every other key in `secrets.env` buys a
*read* and this one buys *compute*.

**Triaged 2026-08-30** from repo config, the two fal client sources, and the live
containers. Measurements are marked; the rest is attributed.

---

## 1. Where this came from

`work/plans/fal-ai-related-host-tasks.md` — 43 checkboxes across 8 headings,
written by an agent that **did not have this repo's context**. That directory is
gitignored (`.gitignore:67`), so the note is not in history and this spec restates
what it needs rather than citing it.

The note is good, and its blind spot is consistent: it assumes a *fleet* of
sandboxes provisioned for *tenants* by *separate parties* — an image owner, an
allowlist owner, a secret-store owner. Here those are one operator, three profiles
(`fluidmomenta`, `nranthony`, `therapod`), and one host-side config file per
concern, all in git. That single mismatch accounts for most of what falls away.

It is also stale in one specific place, and the correction matters:

> "Known: `mcp.fal.ai` 200, `*.fal.media` reachable, `fal.ai` 403."

Three errors. The `[fal]` block is **gated and commented out in HEAD** — every one
of its hosts is 403 in the committed baseline, `mcp.fal.ai` included. (It is
uncommented in the current working tree, which is a transient state, not the
posture.) `*.fal.media` is **not squid `dstdomain` syntax** — it matches literally,
matches nothing, and reads as present while denying; the real entry is
`.fal.media`, leading dot. And the apex `fal.ai` is 403 because it was never in the
list and deliberately is not — see §5.1.

## 2. Triage

| | Count | Meaning |
|---|---|---|
| **Answered** | 17 | An existing ADR, script or test already decides it. §3. |
| **Not applicable** | 4 | Presumes an architecture this is not. §4. |
| **Open** | 22 | Real here. Collapse into five findings (§5) and five gates (§6). |

## 3. Answered — 17 items, with the thing that answers them

| Source item | Answer |
|---|---|
| 1.4 baked / per-sandbox / per-repo allowlist, who amends | **None of those.** One host-side file, `proxy/allowed_domains.txt`, in git, mounted `./proxy:/etc/squid/host:ro` as a **directory** and shared by every profile's proxy. Amended by editing it; `squid -k reconfigure` picks it up. [ADR-0003](../../docs/adr/0003-strict-egress-default.md). Caveat worth knowing: the Streamlit dashboard rewrites this file wholesale, so hand-added blocks can vanish — check `git diff` after using it. |
| 1.6 update / telemetry endpoints allowed or blocked | **Blocked, by construction.** Default-deny: a host not listed is 403. No decision needed; the residual question (does the client hard-fail on a blocked telemetry call?) folds into D1's real run. |
| 2.1 injection point; "image layers are readable and exportable" | **Nothing is ever baked.** `secrets.env` is an *optional* `env_file` (`required: false`) at `~/.ai-sandbox/profiles/<p>/secrets.env`, outside the repo tree, `chmod 600` by `profile.sh`. It reaches no image layer and no downstream consumer. |
| 2.4 rotation — how in-flight sandboxes are handled | **`env_file` is read only at container CREATE.** So rotation costs a `scripts/profile.sh <p> recreate`; a plain `up` will not re-read it. That mechanic *is* the in-flight answer. Cadence is policy, folded into D3. |
| 2.6 visible to agent process, shell, both, or neither | **Both** — and this is the finding, not a checkbox. See §5.3. |
| 4.2 pin versions, rebuild trigger and cadence | Established pattern: pin in the `Dockerfile`, Gate 2/3 quarantine applies at build time, `--refresh-ai` bumps the tail layer, and AGENTS.md's boundary-monitor rule requires a detector in `just check-upstreams` for any new vendored payload. |
| 4.3 self-update disabled? drift across long-lived sandboxes | Repo posture is already no-self-update (an in-container `claude` self-update is a known breakage, not a feature). Drift is `check-upstreams`. |
| 4.4 install location survival + executable | The state-placement table in AGENTS.md decides it. Note `/tmp` is `noexec` (verify asserts the `just` shebang workaround) and `/root` scratch is tmpfs. |
| 4.6 how a consumer discovers what is installed | `scripts/profile.sh <p> verify` prints per-tool presence lines. |
| 5.1 skill level: image / user-global / per-sandbox / per-repo | **Templates in this repo, converged into every profile on `up`** — [ADR-0005](../../docs/adr/0005-skill-templates-are-source-of-truth.md), extended to policy by [ADR-0007](../../docs/adr/0007-policy-templates-are-source-of-truth-for-every-agent.md). The note's worry that "image-level content is invisible to anyone reading the repo" inverts here: the templates *are* the repo. |
| 5.2 directory divergence, symlink strategies breaking on Windows | Convergence **mirrors by copy**, never symlinks; `profile-skills.test.sh` (24/24) locks it. No Windows checkout exists — the substrates are WSL2 and bare Linux. |
| 5.3 is a registry-installed bundle reviewed before it lands? | `scripts/vendor-tools.sh` is the only door: every hash verified **before anything is copied**, plus a content diff against the claimed source commit. `vendor-tools.test.sh` (65/65). 0019 §2.3 is the worked example of what this catches — a plugin bringing 42 skills nobody asked for. |
| 5.5 update path for a corrected skill | Converge on the next `up`. Same ADR-0005. |
| 5.6 portable knowledge vs repo-specific seams | Pattern exists: `sandbox_templates/skills/web-read/SKILL.md`. Follow it if D5 produces a skill. |
| 6.4 what a consumer does when neither backend is reachable | **Unreachable is the normal state** under default-deny. The gated block means "no fal" is the resting posture, not an error path. |
| 7.5 a sandbox without the tooling degrades cleanly | Same answer: no key set, block closed, `webfetch`-style absence. Confirm in D1's run, do not design for it. |
| 8.1 who owns image, allowlist, secret store — same party? | **One operator owns all three.** The question presumes separation that does not exist. |

## 4. Not applicable — 4 items

- **2.2 scope: per-repo / per-session / per-tenant key.** The only unit the mechanism can express is the **profile**. Three profiles, one operator, no tenants. The live part of this question — *which* profiles get a real value — is real and lives in D3.
- **5.4 licensing of vendored third-party instruction content.** Nothing third-party is proposed. Becomes live only if D5 chooses to vendor a skill from elsewhere, at which point `vendor-tools.sh` and `UPSTREAM.md` already carry it.
- **6.3 is the fallback provisioned everywhere or only where the primary cannot land?** Presumes a fleet with varying capability. Three profiles built from one shared image.
- **8.1's second half** — see §3.

## 5. The five findings that survive

### 5.1 No working run has ever happened. The host list is a probe plus a source read.

The six hosts in `[fal]` have two provenances, and neither is a completed job:

- `mcp.fal.ai`, `api.fal.ai`, `fal.run`, `queue.fal.run` — **observed** 2026-08-29 in
  `egress-proxy-fluidmomenta` `access.log`: four `TCP_DENIED/403` CONNECTs inside
  64ms. That is a **reachability probe**, explicitly not a working run.
- `rest.fal.ai` — **read out of both client sources** 2026-08-30 (`fal_client/client.py`
  `REST_URL`, `@fal-ai/client` `config.ts getRestApiUrl()`). It replaced
  `rest.alpha.fal.ai`, which was in the hand-written list this block came from and
  appears in **neither client and in no log line**. The list was denying the host
  that is called and permitting one nothing calls.
- `.fal.media` — the one wildcard, kept deliberately wider than the source names
  (`CDN_URL = "https://v3.fal.media"`) because fal versions its media hosts. The
  audit probe reports every leading-dot entry as INFO for periodic review
  (`scripts/audit/probes/proxy.py:131`).

So source item **1.1** — *"capture from a real run, not from docs"* — is this
repo's own rule, stated in 0016 and proven twice by `[pytorch]` needing three
hosts found one at a time. It is unmet. **1.3** (do download redirects land inside
the `.fal.media` wildcard?) cannot be answered any other way.

The `rest.alpha.fal.ai` episode is also the concrete instance of **8.2**: a
provider-side host list drifted and nothing here detected it. It was found by
reading source, by hand, once.

### 5.2 A paid submit can be orphaned by a mid-job denial — and the evidence is on tmpfs

This is the item with no precedent anywhere in the repo, and the reason the
external note earns its keep. Source item **1.5**.

fal meters at **submit**. The cycle is submit → poll → download, across at least
three different hosts (`queue.fal.run`, `rest.fal.ai`, `*.fal.media`). A denial on
the *first* leg is free and loud. A denial on the poll or download leg means the
money is spent, the artifact exists on fal's side, and the local process sees a
connection error indistinguishable from a network blip.

Two things make it worse here:

- `scripts/with-egress.sh` opens a gated block **for the duration of one command**
  and closes it after. A job that outlives its widening loses its egress *by
  design*, mid-flight.
- `/var/log/squid` is **tmpfs, 64m** (`docker-compose.yml:241`). The `TCP_DENIED`
  line that would tell you which leg died does not survive a proxy restart, and
  rolls at 64m. Proxy failures here are already known to be forensically silent.

Source item **7.2** — "verify a submitted job is pollable and retrievable after the
session dies" — is the recovery half of the same finding, and it needs the request
id written somewhere durable (the workspace bind mount), not to tmpfs or a
transcript.

### 5.3 This is the first key in `secrets.env` the agent can spend by itself

Source items **2.6, 2.7, 7.3**. The mechanism is honest and the consequence is not
comfortable:

- `env_file` puts `FAL_KEY` in the **container's environment**. The agent can read
  it (`env`, `/proc/self/environ`) and call fal directly with `curl`-equivalents.
- That is *unlike* every other key in the file. `TAVILY_API_KEY` and friends are
  read by `sandbox_templates/bin/webfetch`, a broker the model does not author
  requests for; `webfetch.test.sh` (90/90) locks that keys travel in headers and
  never in URLs, because Squid logs URLs. **There is no equivalent lock on a fal
  call path, because there is no fal call path yet.**
- Therefore source item **7.3** — "confirm no credential appears in environment
  dumps" — **fails as written** and must be restated rather than checked off. The
  correct claim is narrower: it appears in the environment by design, and is kept
  out of *argv, URLs, logs, and git* by the header rule.

The template written 2026-08-30 states the naming evidence (`FAL_KEY` canonical;
`FAL_KEY_ID`+`FAL_KEY_SECRET` legacy and AND-checked; `Authorization: Key`, not
`Bearer`) and the header rule. It does not, and cannot, make the key invisible to
the agent.

Source items **2.3** (scoped/revocable keys) and **2.5** (revocation speed) are
provider-side and **unverified** — see §9.

### 5.4 Spend has no cap, no telemetry, and no attribution

Source items **3.1, 3.3, 3.5, 8.3**. Measured: nothing in this repo tracks cost.
There is no cost log, no per-profile meter, no budget check.

- **3.3** — "where does cost telemetry land?" **Nowhere.** Squid's `access.log` is
  the only per-profile network record and it is tmpfs (§5.2).
- **3.5 / 8.3** — attribution after the fact is impossible **if one key is shared
  across the three profiles**, because fal's side cannot distinguish them either.
  Per-profile keys would make it attributable at the provider. That is the live
  half of source item 2.2, and it lands in D3.
- **3.2** — blast radius. The genuine mitigation already exists and is worth
  naming: the `[fal]` block is gated, so an unattended loop can only spend while a
  `with-egress.sh --with fal` widening is active. That bounds it in wall-clock, not
  in dollars.
- **3.4** — the cheap/expensive boundary maps onto machinery this repo already has:
  `deny-destructive.sh` is a **three-tier** engine (warn / ask / deny) and a claude
  `ask` in a headless or subagent context is a deny carrying the reason. A fal
  submit is exactly the shape of thing the ask tier exists for.

### 5.5 Nothing is installed — no client, no CLI, and no ffmpeg

Source items **4.1, 4.5, 6.1, 6.2**. Measured in `ai-sandbox-nranthony`,
2026-08-30:

- no `fal` CLI, no `fal_client` module (`ModuleNotFoundError`);
- **no `ffmpeg`** — not in the `Dockerfile`, not on `PATH`.

The last one is source item 4.5 landing squarely: generated **video** would arrive
as bytes nothing in the container can transcode, inspect, or thumbnail. Whatever
D5 decides, that gap is real and independent of it.

**6.1/6.2** — backend selection — has a precedent to follow and one option the
external note could not see:

- Precedent: [ADR-0011](../../docs/adr/0011-web-read-backends-are-peers-with-no-default.md)
  — web-read backends are **peers with no default**, knowledge written once,
  invocation swappable. That is source item 6.2, already decided as a principle.
- The option it could not see: **ComfyUI already runs inside the boundary** (0016),
  on the local GPU, for free, with zero always-on egress. For a large share of
  image work, "use fal" and "use the thing already here" are competing answers, and
  the free one does not raise §5.2, §5.3 or §5.4 at all.

## 6. DECISIONS — present to the owner before implementing

### D1 — do a real end-to-end run first, or provision from the current list?

Source items 1.1, 1.3, 7.1, 7.4, 8.2. **Recommended: run first.** One scratch
job via `scripts/run-ephemeral.sh` under the production ACL and secret path,
capturing `access.log` live (it is tmpfs — capture during, or never), answering:
every host on submit → poll → download; whether download redirects stay inside
`.fal.media`; what a denied host looks like from the client; what an expired key
looks like. Everything else in this spec is cheaper after that run.

### D2 — what is the failure signal when a leg is denied mid-job?

Source items 1.5, 7.2. Options: (a) accept the orphan risk, document it; (b)
persist the fal request id to the workspace on submit so any later session can
poll and retrieve; (c) refuse to submit unless the widening window is long
enough to cover the job. (b) is cheap and is the recovery half of 7.2.

### D3 — one key across three profiles, or one per profile? And which profiles?

Source items 2.2 (live half), 2.8, 3.5, 8.3, plus rotation cadence from 2.4.
Per-profile keys are the only way to get provider-side attribution. Against:
three keys to rotate, each costing a `recreate`. The placeholder is commented in
all three `secrets.env` files as of 2026-08-30 — no profile has a value.

### D4 — is a fal submit an `ask`?

Source item 3.4. If yes, it is a rule in `deny-destructive.sh` and the suite grows;
the ask tier is dialect-branched (claude `ask` / agy `force_ask`) and both arms
must be written. If no, the only control is the gated block plus whatever cap D3's
key model supports.

### D5 — what, if anything, gets installed?

Source items 4.1, 4.5, 6.1. Three separable questions: the **client** (pinned
`fal_client` below Gate 3 / the MCP endpoint at `mcp.fal.ai`, which inherits
0019's D3 problem of where an `mcpServers` entry can live and survive converge /
nothing, calling the REST API directly); the **skill** (one, ADR-0011-shaped,
naming fal and local ComfyUI as peers); and **`ffmpeg`**, which is a plain
"yes/no, and if yes it is a `Dockerfile` line with a rebuild".

## 7. Steps, after §6 sign-off

1. D1's ephemeral run, `access.log` captured live. Write the observed host set into
   the `[fal]` block by name, and **delete** any line the run never produced —
   the block's own instruction.
2. Add a `[fal]` line to `just check-upstreams` only if D5 bakes something; the
   host list itself has no detector and §5.1 is the argument for giving it one.
3. Whatever D2/D3/D4 decide, in the surface that owns it — allowlist, secrets
   template, hook engine — each with its own suite run.
4. Docs: ARCHITECTURE.md only if D5 changes the image.

## 8. Non-goals

- Reopening 0016's decision to run ComfyUI locally. This item may conclude fal is
  not needed for most work; that is a *use* decision, not a reversal.
- Any always-on egress. `[fal]` stays gated whatever is decided.
- Baking a key anywhere. §3, source item 2.1.

## 9. Unverified — do not present these as fact

- **fal's key model.** Whether keys can be scoped, whether spend caps exist per key
  or per account, and how fast revocation takes effect (source items 2.3, 2.5,
  3.1). Not checked. The external note's framing — "in-repo instruction files are
  advisory only" — is correct regardless: if no enforceable cap exists provider-side,
  the gated block is the *only* real bound.
- **fal's pricing granularity**, and whether any per-request cost is returned in a
  response header that could be logged locally.
- **Whether `mcp.fal.ai` speaks streamable-HTTP MCP** and how it authenticates
  beyond "the same key". Assumed, not measured.
- The claim that a denial on the download leg leaves the artifact retrievable
  later. Plausible from the queue API's shape; untested (D1/D2).
