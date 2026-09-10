# 0025 — The notice says the registries are CLOSED; PyPI and PyTorch are open

**Status: Draft** — opened 2026-09-09 out of a read-through of the deployed
notice in a consumer repo (`~/repo/nranthony/jeremy_dahl_analytics/AGENTS.md`).

The notice is **in sync with its source** — the deployed block is byte-identical
to `sandbox_templates/common/agent-notice.md` at HEAD (diff = the BEGIN/END
markers only) across all 22 targets, and `agent-notice.test.sh` is 13/13. The
defect is upstream of the sync: **the template's claims have drifted from live
posture, and nothing in the suite can see that class of drift.** One of the four
is a live egress gap, not a documentation error.

**Branch:** none yet. Measured from `feat/0023-ollama-sibling` @ `e8ba771`.

---

## 1. What was measured (2026-09-09, do not re-measure)

Live containers, host-side reads. Nothing was changed.

| Claim under test | Result |
|---|---|
| Deployed notice == template | `diff` clean but for the two marker lines |
| Notice suite | `agent-notice.test.sh` 13/13 |
| Fan-out size | 19 repo `AGENTS.md` + 3 profile `claude-home/CLAUDE.md` carry the block |
| PyPI reachable from the agent | `curl https://pypi.org/simple/requests/` → **200** |
| PyTorch reachable | `curl https://download.pytorch.org/whl/cu126/` → **200** |
| npm reachable | `curl https://registry.npmjs.org/left-pad` → **000** (blocked) |
| Allowlist state | `.pypi.org` / `.files.pythonhosted.org` / `.astral.sh` (`:330-332`) and the three `[pytorch]` hosts (`:357-359`) uncommented **in committed state**; 82 live domains |
| Proxy agrees with the file | `egress-proxy-nranthony` sees the same 82 — this is enforced, not just on disk |
| Age gate in the agent env | **no `UV_EXCLUDE_NEWER`** — only `UV_LINK_MODE`, `UV_PYTHON_*`, `UV_TOOL_*` |
| `uv run` status | `Bash(uv run:*)` is in `permissions.allow`; `uv add`/`uv sync`/`uv pip install`/`pip install` all denied |
| Secrets deny patterns | `Read(**/.credentials*)` — **dot-prefixed**; `Read(**/.env.*)`, `Read(**/*.pem)`, `Read(**/*.key)` |
| Consumer WebFetch scoping | `jeremy_dahl_analytics/.claude/settings.json` → `"permissions": {}` (zero `WebFetch(domain:)` entries) |
| Ollama sibling | `ollama-nranthony` up, reachable at `http://ollama:11434` via `NO_PROXY`; absent from the notice |

Everything else the notice asserts was cross-checked against live policy and
**holds**: the full deny set (`curl`/`wget`, the fetch-and-run family, remote git
+ `git config` + `gh`/`glab`, the shell-escape set, `reset --hard`/`rebase`), the
three hook tiers incl. `git clean` denied by the hook rather than the static list,
tmpfs/noexec paths, the persistent mounts, `postgres:5432` / `mongo:27017`,
`/usr/lib/wsl/lib/nvidia-smi`, and the `webfetch` contract (four backends, `--via`
required, no default).

## 2. The four defects

### 2.1 — LIVE GAP. "The package registries — PyPI, npm, PyTorch — are currently CLOSED"

False for two of three, and the consequence is not confined to the doc.

Install *commands* are still denied, so the notice's advice is followed for the
obvious path. But `uv run` is allowed and auto-syncs. With `[pypi]` open, no
`UV_EXCLUDE_NEWER` in the container env, and no project `[tool.uv] exclude-newer`
in the workspace repos checked, the sequence **manifest edit → `uv run`** resolves
live from PyPI with:

- no 7-day age gate (that timestamp is computed and injected by `with-egress.sh`,
  which is not in this path),
- no `depgate.jsonl` install-audit entry — the log stays silent, which reads
  identically to a clean run,
- no lockfile-strict form.

That is precisely the trust decision the notice's §Dependencies rules 1–5 exist
to backstop, with the network layer underneath them open. It is the same hole
[0019 §5.2(a)](../0019-comfyui-mcp-in-the-image/spec.md) records from the other
end (`install_node` / `update_comfyui` driving `pip` outside the audit log) —
recorded there on 2026-08-31 as "`[pypi]` is **always-on**", while the notice and
the allowlist header both say the opposite. **Two internal documents already
disagree about this; the disagreement has been live for at least nine days.**

### 2.2 — OVERCLAIM. The secrets bullet promises coverage that does not exist

Notice: "`.env`, `*.env.*`, `*.key`, `*.pem`, `**/credentials` are unreadable."
Actual: `Read(**/.credentials*)` — **dot-prefixed**. `google_sheets_credentials.json`
sits at the root of `jeremy_dahl_analytics` and is readable. `*.env.*` likewise
reads wider than the real `Read(**/.env.*)`: `prod.env.local` is not covered.

Same family as [0019 §5.2(c)](../0019-comfyui-mcp-in-the-image/spec.md)
(`Read(**/.credentials*)` misses comfy-cli's `secrets.json`). A notice promising a
control that is not there is worse than silence: the agent reads it and does not
check, which is the failure mode `agent-notice.test.sh` was built for on the
fetch-and-run axis and does not cover here.

### 2.3 — UNREALISED. The WebFetch paragraph describes config that is not present

The mechanism is right, but "scoped per repo with `WebFetch(domain:<host>)`
entries in that repo's local Claude settings" is zero entries in the repo checked.
Every `WebFetch` prompts. Low severity — the notice's instruction ("accept the
prompt or use `webfetch`") still lands — but the sentence implies a configured
allowance the agent will not find.

### 2.4 — PENDING, not stale. The Ollama sibling is missing

`ollama-<p>` is live for `nranthony` now and reachable at `http://ollama:11434`.
The "Databases aren't on `localhost`" bullet names postgres and mongo only, and
nothing says the agent's own backend may be a local model
(`profile.sh <p> backend ollama|openrouter|anthropic`). This is
[0023](../0023-ollama-sibling-container/spec.md) on an unmerged branch, so the
notice is not wrong yet — it becomes wrong on merge.

## 3. How it got here

`f253f9d` (2026-08-28), *"security(proxy): [pytorch] needs three hosts, not one —
**both CLOSED**"*. The message states "this adds two hosts to the already-gated,
still-commented `[pytorch]` block" and "Verified after re-closing: 69 live
domains". Its diff uncomments `.pypi.org`, `.files.pythonhosted.org`, `.astral.sh`
and adds the three `[pytorch]` hosts live. `git blame` puts the current open state
on that commit; live count today is 82.

Whether that was a `with-egress` session captured into the commit or a deliberate
change described wrongly is **the owner's to say** — the mechanism is consistent
with either (`open_section` is idempotent on an already-open block, and the
restore is verbatim from a saved copy, so a later `--with pypi` run leaves no
trace either way).

The structural point is the one this item exists for: AGENTS.md's rule for
security-sensitive files is *"the commit message states the security impact"*.
That rule was satisfied **in form** by a statement that was false, and nothing
checked it. `verify` compares the running proxy to the file; nothing compares the
file to what the documentation promises.

## 4. Decision gates

- **D1 — Re-close `[pypi]` and `[pytorch]`, or accept them open and rewrite the
  claim?** Everything else in this item is downstream of the answer: the notice
  text, [0019 §5.2(a)](../0019-comfyui-mcp-in-the-image/spec.md)'s residual, and
  whether the `uv run` auto-sync path needs a control of its own. Re-closing
  restores the stated posture at the cost of `--with pypi` on every Python
  install; accepting means the age gate and the audit log have a documented hole
  that `with-egress.sh` cannot cover, and the notice must say so plainly rather
  than claiming a network control that is not enforced.
- **D2 — Widen the deny patterns, or narrow the notice text?** `Read(**/*credentials*)`
  and `Read(**/*.env.*)` would make the promise true and would also close
  0019 §5.2(c); the cost is denying reads of legitimately-named files. Narrowing
  the notice is free and honest but leaves the gap. These are separable per
  pattern — the credentials half is the one with a live example.
- **D3 — Where does the posture lock live?** Candidate: an assertion in
  `agent-notice.test.sh` that every registry the notice names as CLOSED is
  commented in `proxy/allowed_domains.txt`, and that every secret pattern the
  notice names has a matching `permissions.deny` entry — the same shape as its
  existing fetch-and-run assertions, offline, no docker. Alternative/additional:
  a live-domain census line in `verify`. The first would have failed red on
  2026-08-28; the second would have caught the commit-message contradiction.
- **D4 — Does the 0023 line land here or on that item's merge?** And does the
  notice's structural change flagged in
  [0022 §10.2](../0022-port-forward-to-macolima/spec.md) (a marked, strippable
  substrate block, so the WSL2/CUDA section does not travel to macolima) belong
  in the same edit? Both touch the same file; doing them separately means two
  fan-outs.

## 5. Work, once D1–D4 are answered

Ordered; 1 is independent of the gates and can ship first.

1. **The lock** (D3). Extend `agent-notice.test.sh`. Offline, no docker. This is
   the piece that makes the rest not recur.
2. **The allowlist action** (D1). Security-sensitive: commit message states the
   impact *and is checked against its own diff this time*;
   `profile.sh <p> verify` then `audit`.
3. **The notice edits** (D1/D2/D4): the registry claim, the secrets bullet, the
   WebFetch sentence, and the Ollama/backend line.
4. **The fan-out.** `sync-agent-notice.sh` writes 22 files across 19 repos and 3
   profiles. It writes; it does not commit — each consumer repo carries its own
   git state and its own owner. Sequence it after 3, and expect the diff to land
   in repos that are mid-work.

## 6. Out of scope

- The substrate-applicability lock itself (0022 §10.2) unless D4 folds it in.
- The `uv run` auto-sync path as a *control* change — if D1 accepts the open
  registry, that becomes its own item, not a widening of this one.
- comfy-cli's plaintext credential store (0019 §5.2(c)) beyond whatever D2's
  pattern change happens to cover.
- macolima. Nothing here is portable until the notice's substrate question is
  settled.

**Exit rule:** archive to `docs/_archive/` with `notes.md` when D1–D4 are
answered and the lock is green.
