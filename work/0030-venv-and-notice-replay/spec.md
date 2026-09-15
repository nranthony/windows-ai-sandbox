# 0030 — replaying macolima's venv rule (0008) and notice homes (0011) here

**Status:** Accepted → [ADR-0013](../../docs/adr/0013-the-environment-names-the-venv.md) + [ADR-0015](../../docs/adr/0015-the-sandbox-briefs-agents-from-their-homes.md).
**Opened:** 2026-09-15, from two human-ferried files in the macolima checkout on
this machine: `macolima/work/0008-venv-per-environment/replay-other-hosts.md`
and `macolima/work/0011-sandbox-notice-global-homes/replay-sibling.md`. Those
two files are the spec; this item records only what differs here and the order.

## 1. What this item is

Two decisions the sibling took and proved on the Mac, run once in this repo
(R1, one PR) and then once per Linux machine (R2–R6):

1. **The environment names the venv** (ADR-0013). The container exports
   `UV_PROJECT_ENVIRONMENT=.venv-sandbox`; a repo's `.venv` is the host's and
   the container never touches it. The deletion hook's disposable carve-out
   moves from `.venv` to `.venv-sandbox`; `verify` asserts the value;
   `workspace-scan.py` is the host-side done-check.
2. **The sandbox briefs agents from their global homes** (ADR-0015). One
   neutral notice, adopted verbatim from macolima, written into
   `claude-home/CLAUDE.md` AND `gemini-home/config/rules/sandbox-notice.md` on
   every `up`/`recreate`/`rebuild`/`converge`; a neutral marker that replaces
   either legacy one; `--strip` for the blocks hand-placed in repos; `verify`
   hashes both home files against the template (`NOTICE_SHA`).

They interlock: 0011's strip is what fixes the repos whose notice block told
agents to `export UV_PROJECT_ENVIRONMENT=.venv-linux`, and it must run before
any 0008 repo handoff is applied here. One work item, one PR, two ADRs — the
0011 replay allows exactly that.

## 2. What differs on this substrate (measured 2026-09-15, WSL2 host)

| | macolima | here |
|---|---|---|
| Agent home | `/home/agent` | `/root` — which is why the shared notice says `~` |
| Docker | Colima, rootful in the VM | rootless (`docker info` Context: rootless) — host-side deletion of container-built venvs needs no `sudo` |
| `UV_PROJECT_ENVIRONMENT` lives in | compose | compose (Dockerfile `ENV` holds `UV_LINK_MODE`; the ADR records why the venv variable does not join it) |
| uv cache | named volume | bind mount `profiles/<p>/cache` → per profile, per machine; every first `.venv-sandbox` build is cold |
| Venv ownership | `pyvenv.cfg` `home` suffices | **shebang only** — host and image share `/usr/bin/python3` |
| Two-hosts exception (`/mnt/c`) | n/a | checked: no `.venv` under `/mnt/c/Users/*/repo*`; none known |
| Host shell exporting `UV_*` | one harmless `UV_PYTHON_INSTALL_DIR` | none (`~/.bashrc`, `~/.zshrc`, `~/.profile`) |
| `just` shebang recipes on noexec `/tmp` | `JUST_TEMPDIR` in compose | already handled by the baked `just` wrapper; `verify` has the probe — nothing to add |
| Notice blocks in checkouts | 10 (Mac) | **21** repos across 3 profiles (19 by whole-line grep; the scanner's prefix match finds 2 more nested/depot copies) |
| `agent-notice.test.sh` | 13 | the same 13; the shared text passes unchanged (measured here) |
| GPU bullets | none | this repo's three CUDA bullets are gone from the shared text; the neutral `/dev/dxg` bullet covers both |
| ADR numbering | 0013, 0015 | same numbers, unused here; 0014 stays reserved (channel-side ADR + macolima's paperbridge item) |
| Registry claim in the notice | "closed by default" | same text; `[pypi]`/`[pytorch]` are OPEN here (work/0025, D1 undecided). Adopting the shared text neither fixes nor worsens it |

## 3. What the replays could not see from the Mac

- `sync-agent-notice.test.sh`'s mode check used `stat -f %Lp || stat -c %a`.
  On GNU `stat -f` is *filesystem* status and exits 0, so the fallback never
  ran and both mode assertions failed on every Linux host. Fixed here (GNU
  first); report back to macolima §3.
- `scripts/sync-agent-files.sh` here has none of macolima's exclusions: a run
  wrote a `CLAUDE.md` stub into the vendored `myconv` scaffold tree and into a
  depaudit fixture. Both removed by hand; the script is unchanged (out of
  scope — noted for whoever next touches it).
- 13 checkouts carry a **container-built venv in the `.venv` slot** (shebang
  `#!/workspace/…`). After the switch the container ignores them and the
  host's uv would recreate them on first use. They are R5's retirement list,
  never a glob.

## 4. Decision gates (owner)

- **D1 — VS Code interpreter on the Windows host** (0008 replay §3.7 / R2):
  keep `/root/.venv` as the default, or point attached windows at
  `${workspaceFolder}/.venv-sandbox/bin/python`? Windows user `settings.json`,
  not a repo file. Decide after the first `.venv-sandbox` exists.
- **D2 — agy global rules** (0011 R4): does `agy -p` repeat a word planted in
  `~/.gemini/config/rules/sandbox-notice.md`? Needs a signed-in profile. If
  negative, drop the second target and re-record the gap.

## 5. Exit

Per machine, the two done-checks exit 0 —
`workspace-scan.py --fail-on HARDCODED-VENV-LINUX,OS-VENV-SELECT` and
`--fail-on NOTICE-IN-REPO` — every profile's `verify` is green on the
`UV_PROJECT_ENVIRONMENT` and both notice lines, and the report-back is in
macolima's two `notes.md` files. Then archive to `docs/_archive/`.
