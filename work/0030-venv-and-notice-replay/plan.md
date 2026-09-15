# 0030 — plan

Order is macolima's: **switch first, repos after** (0008 replay §4). Until a
profile is recreated with the variable, a container `uv run` in a repo with a
host `.venv` is itself the destructive command — quietly, on this substrate.

| Step | What | Who | State |
|---|---|---|---|
| R3a | Scan, first pass (`just workspace-scan --out work/0030-…/scan.local.md`) | agent | **done 2026-09-15** — 52 repos, counts in notes.md |
| R1 | This repo, one PR: compose variable · hook carve-out + 3 locks · shared notice verbatim · neutral sync script + `--strip` + its 72-case suite · second target at both `profile.sh` sites · `NOTICE_SHA` on the verify exec + the two in-container checks · `workspace-scan.py` + suite + `just workspace-scan` · `.local` pair in `.gitignore`/`.dockerignore` · ADR-0013 + ADR-0015 · doc rewrites (AGENTS.md, docs/index.md, extending-a-profile, profile-lifecycle skill, local-wheels, hook plan, ARCHITECTURE) · `just test-offline` | agent | **done 2026-09-15**, branch `dev/0030-venv-and-notice-replay` |
| B8 | Prove the rule in one shell inside a running container, variable prefixed per command, `--offline`, against a real checkout; host `.venv` byte-identical after | owner at the prompt | open |
| merge | Merge R1. From here any profile's next recreate switches it | owner | open |
| R4a | **Recreate every profile in one sitting**; `just verify <p>` each: `UV_PROJECT_ENVIRONMENT=.venv-sandbox` PASS, both notice lines PASS | owner | open |
| R4b | Pull the shared repos — the pulls carry the Mac's strips AND the venv edits, which is why they wait for the switch | owner | open |
| R2 | `--strip` whatever still carries a block after the pulls (`just workspace-scan --fail-on NOTICE-IN-REPO` lists them). **Read the region first** — on the Mac 4 of 10 held repo text inside the markers (ikigai: live Postgres docs; app_blast: a webfetch rule; myclickup/paperbridge: a lockfile bullet). Move such text below the markers, strip, diff, one commit per repo; then grep `notice above`/`notice block` and reword to `~/.claude/CLAUDE.md`, separate commit | agent, per repo | open |
| R3b | Re-run the scan on the day; `--fail-on HARDCODED-VENV-LINUX,OS-VENV-SELECT` names the repos that get a 0008 handoff (final form, citing agentic-conventions ADR-0017; precondition `echo $UV_PROJECT_ENVIRONMENT` = `.venv-sandbox`) | agent | open |
| R4c | Per active repo: pin `.python-version` (3.12 unless the repo needs 3.13) → `uv sync --frozen` with like-for-like extras, in a **scripted** egress window (cold cache here) → the repo's gate → re-comment the planning-mode domains | owner opens egress; agent syncs | open |
| D1 | VS Code Windows interpreter setting (spec §4) | owner | open |
| D2 | agy global-rules measurement (spec §4) | owner (needs sign-in) | open |
| R5 | Retire: the 13 `SANDBOX-VENV-IN-HOST-SLOT` venvs, the 3 `.venv-linux` slots — classified by shebang, deleted by name, after a soak | owner | open |
| R6 | Hosts: no `UV_PROJECT_ENVIRONMENT` export anywhere (checked clean 2026-09-15); global `~/.claude/CLAUDE.md` venv line per macolima plan D2 | owner | open |
| report | Into macolima `work/0008/notes.md` and `work/0011/notes.md` (spec §5 of each replay) | agent | open |

**Rollback** until R5: remove the compose line and recreate. Old venvs are
still on disk; a stray `.venv-sandbox` is harmless.

**Other machines** (bare Linux): same steps from R3a; this item's notes are
the corrections file, per replay §0.3.
