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
