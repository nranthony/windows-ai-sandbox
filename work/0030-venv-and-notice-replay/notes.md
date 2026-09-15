# 0030 — notes

## 2026-09-15 — R3a scan + R1 built

**Machine:** WSL2 (Ubuntu 24.04, x86_64), rootless Docker. Profiles:
fluidmomenta, nranthony, therapod. Host `/tmp` is not noexec (container's is;
the `just` wrapper already handles it).

**R1 on branch `dev/0030-venv-and-notice-replay`.** `just test-offline`: all
twelve suites green (hook 219, depaudit 56, with-egress 82, dockerfile 8,
skills 24, vendor 76, notice 13, sync-notice 72, scan 49, policy 53, webfetch
90, private-names) then `check-upstreams`. `PROFILE=_test docker compose
config` shows the variable. Host-side proof that `verify`'s awk+sha256 region
hash of a file the sync script writes equals the template's hash: matches.

**Corrections found while porting (for macolima §3):**
1. `sync-agent-notice.test.sh` mode check: `stat -f` first is BSD-only; on
   GNU it is filesystem status and succeeds, so both mode assertions failed
   here. Now `stat -c %a` first, `stat -f %Lp` fallback.
2. Notice-block count by prefix is **21**, not the 19 a whole-line grep gives —
   the two depot members (`myclickup`, `paperbridge`) with the wrapped
   hand-written BEGIN, exactly as 0011 §3.1 predicted.

**Scan (52 repos; full report is `scan.local.md`, ignored, local only):**

| Flag | Repos |
|---|---|
| NOTICE-IN-REPO | 21 |
| SANDBOX-VENV-IN-HOST-SLOT | 13 |
| HARDCODED-VENV-LINUX | 5 |
| DOC-VENV-LINUX | 7 |
| VENV-PATH-IN-CODE | 5 |
| LEGACY-VENV-SLOT | 3 |
| OS-VENV-SELECT | 2 |
| TRACKED-LOCAL | 2 |
| VENV-OWNER-UNKNOWN | 1 |
| NO-LOCAL-IGNORE | 52 |
| NO-VENV-SANDBOX-IGNORE | 27 |
| NO-PYTHON-VERSION | 26 |

Both done-checks exit 1 today, as expected before R2/R4.

**Repos needing action** (names only for these; the rest stays in the local
report):
- 0008 gate (`HARDCODED-VENV-LINUX` / `OS-VENV-SELECT`): nranthony/ikigai,
  nranthony/job_search_agent, nranthony/my-next-gen-emory, therapod/misc,
  therapod/pipeline. ikigai, misc and pipeline are shared with the Mac and
  already have handoffs applied there — their pulls (R4b) should clear them;
  job_search_agent and my-next-gen-emory are **this machine only** and get
  their handoff from here.
- `.venv-linux` slots to retire (R5): nranthony/job_search_agent,
  nranthony/my-next-gen-emory, therapod/pipeline.
- Container-built venvs in `.venv` slots (R5, after `.venv-sandbox` exists):
  fluidmomenta/legal, nranthony/biohub-kaggle-2026, nranthony/depot/myclickup,
  nranthony/depot/paperbridge, nranthony/ikigai, nranthony/jeremy_dahl_analytics,
  nranthony/mlpipe, nranthony/my-next-gen-emory, nranthony/my_comfyui,
  nranthony/numerai, nranthony/project_zenbu, nranthony/shrec,
  therapod/citation_tools.
- Notice blocks (R2, after the pulls): 21 listed in the local report; the
  fluidmomenta pair (`legal`, `agentic_admin_research_ga`) and the nranthony
  set are not in macolima's ten, so they will still carry a block after R4b.
- Tracked `.local` files needing an owner decision: nranthony/biogentic,
  therapod/app_blast.
- fluidmomenta/agentic_admin_research_ga: a venv with no console script —
  owner unknown; read it before R5.

**Not done here, by design:** B8, the merge, the recreates, the pulls, the
strips, the egress windows, D1, D2, R5, R6 — each is either the owner's or
sequenced after the switch (plan.md).

## 2026-09-15 — B8, merge, recreates, pulls, strips, handoffs, re-scan

**Owner's steps (from the console log):** B8 passed in `mlpipe` (`.venv-sandbox`
created, `.venv` timestamp unchanged; uv picked 3.13 because mlpipe is
unpinned). Merged as `8c3ed16`. All three profiles recreated in one sitting;
`verify` green on every profile: `UV_PROJECT_ENVIRONMENT=.venv-sandbox` PASS,
both `sandbox-notice current in …` PASS (59/60/58 passed, 0 failed; the WARNs
are pre-existing project opt-outs plus therapod's converge discarding a
`modelSettings` key, captured). Pulls done across the three workspaces.

**Three therapod pulls needed hands** (none about a venv): `app_blast` had one
local docs-only commit superseded by the remote's release record — rebased,
the stale commit dropped (`e12666e` in reflog). `citation_tools` and `misc`
both carried an uncommitted local AGENTS.md migration draft with a block,
colliding with the Mac's edits: stashed, pulled, the real WIP restored
uncommitted (citation_tools), and misc migrated on top of the pulled text
(`6e88678`). Stashes kept in both.

**Finding: the Mac's strips were never pushed.** ikigai, pipeline, myclickup
and paperbridge pulled their venv edits and still carried a block. So R2 ran
here for every block, 19 after the two above:
- 15 pure-template blocks stripped; 10 committed (AGENTS.md alone, per repo):
  agentic_admin_research_ga `5794b9d`, legal `1ff4736`,
  jeremy_dahl_analytics `0ed066c`, mlpipe `eeb4e39`, numerai `d159d48`,
  project_zenbu (strip recommitted so a pre-existing uncommitted edit to the
  same file stayed out of it), shrec `3168a9e`, taichi_start_moves `59231bb`,
  engine `616cba9`, pipeline `dfcee05`. Five stripped but **not committed**
  because their AGENTS.md is untracked — another uncommitted migration draft
  in each: job_hunt_rag, my-agentic-tools, pfm-sfi, therapod/core,
  wearable_publications. Owner decides what to commit there.
- 4 blocks held repo-authored text, moved below the markers before the strip:
  myclickup `3e6b53c` (version-bump note), paperbridge `6240bb6` (lockfile
  note), ikigai `82cc179` (live Postgres notes moved; the 2026-09-04/06
  "registry open / uv sync denied / .venv irreplaceable" paragraph DROPPED —
  pre-switch state, superseded by ikigai's own ADR-0022 in the body),
  app_blast `366dcf8` (the webfetch operating rule). The Mac moved the same
  passages on its side; if it pushes, expect a textual conflict in these four
  rather than a clean merge.
- 3 dangling "notice above" references reworded to `~/.claude/CLAUDE.md`,
  separate commits: ikigai `50a3c7f`, jeremy_dahl_analytics `e710f0c`,
  pipeline `336a089`.
- Modes: `--strip` kept every file's mode (644, 600 and 666 as found).

**Handoffs** for the two machine-only repos, final form: `handoff-job_search_agent.md`
and `handoff-my-next-gen-emory.md` beside this file, delivered to
`~/repo/nranthony/inbox/0030/` (workspace root, outside every repo; seen as
`/workspace/inbox/0030/`).

**Re-scan (R3b):**

| Done-check | Exit |
|---|---|
| `--fail-on NOTICE-IN-REPO` (0011) | **0** |
| `--fail-on HARDCODED-VENV-LINUX,OS-VENV-SELECT` (0008) | 1 — job_search_agent, my-next-gen-emory: the two handoffs above |

Left for later waves, per macolima's plan: `DOC-VENV-LINUX` in jeremy_dahl_analytics, core, pipeline (docs mentions, `uv run` when next edited); `VENV-PATH-IN-CODE` in jeremy_dahl_analytics, numerai, project_zenbu; `LEGACY-VENV-SLOT` ×3 and `SANDBOX-VENV-IN-HOST-SLOT` ×13 are R5.
