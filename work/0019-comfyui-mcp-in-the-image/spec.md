# 0019 — ComfyUI MCP in the sandbox

**Status: Parked — on hold 2026-08-31.** Not rejected and not implemented: the
thing this item proposed building was superseded by a different package that
shipped through a different door, and the remaining decisions are deliberately
deferred behind an accepted-risk posture (§5). Unpark conditions in §7.

**Companion:** [`comfy-mcp-direction-comparison.md`](comfy-mcp-direction-comparison.md)
— the owner's npm-vs-PyPI direction comparison, written in a separate session.
This file is the record; that file is the reasoning that produced §4 and §6.

**Original scope (2026-08-28):** bake `comfyui-mcp` (npm) into the shared image
at a pinned version below Gate 2, and register it under `mcpServers` in each
profile's `claude.json` via a third `AGENT_POLICY_DESCRIPTORS` row.
**That is not what happened, and should not now happen** — see §2 and §3.

---

## 1. The correction that parks this item

**This spec was written against the wrong package.** The two names differ by one
character, in different ecosystems, by different authors:

| | This spec's subject | What is actually installed |
|---|---|---|
| Package | `comfyui-mcp` (npm) | `comfy-mcp` **0.10.0** (PyPI) |
| Author | `artokun`, third-party | **Comfy Org** — ComfyUI upstream |
| Self-description | — | "MCP server for ComfyUI — a thin wrapper over `comfy-cli`" |
| License | — | AGPL-3.0-or-later OR LicenseRef-Comfy-Commercial |
| Runtime deps | 10, two native (`better-sqlite3`, `sharp`) | 3: `mcp`, `pydantic`, `anyio` |
| Cadence | 454 releases in 6 months (§3.1 below) | 0.10.0 |
| Delivery | proposed: baked into the image | `.venv`, pinned in `requirements.lock` |
| Tools | 38 claimed upstream | **39** (`@mcp.tool(` decorators, counted) |

Nothing in §2–§3.2 of the original text was wrong *about the npm package*. It
was simply answering a question that stopped being the live one on 2026-08-29.

## 2. What actually shipped

`~/repo/nranthony/my_comfyui/.mcp.json` (tracked):

```json
{"mcpServers": {"comfy": {
  "command": "/workspace/my_comfyui/.venv/bin/comfy-mcp",
  "env": {"COMFY_BIN": "/workspace/my_comfyui/.venv/bin/comfy"}}}}
```

Enabled by `.claude/settings.local.json` → `enabledMcpjsonServers: ["comfy"]`
(gitignored, per-machine opt-in). Target is comfy-cli's own config, not the
JSON: `config/comfy-cli/config.ini` has `where_default = local`,
`default_workspace = /workspace/my_comfyui/comfyui`, `enable_tracking = False`.

### Provenance — it came through the intended door

`audit/depgate.jsonl` entry 27, 2026-08-29,
`uv pip install "comfy-cli>=1.14.0" comfy-mcp`:

- `sections: ["pypi"]`, `denied: []`, `rc: 0`
- `py_age_gate: {applied: true, exclude_newer: "2026-08-22T19:04:16Z", window_days: 7}`
  — the age gate held; **no `--allow-fresh`**
- `preflight`: both packages `NO-KNOWN-MAL`

Landed `comfy-cli==1.17.0` + `comfy-mcp==0.10.0`, both pinned in
`requirements.lock`. This is `with-egress.sh` working exactly as designed, and
it is the reason no image change is needed.

## 3. Disposition of the original proposal

Every objection this spec raised was against the npm package. None survives
contact with what is installed:

| § | Objection | Status against `comfy-mcp` (PyPI) |
|---|---|---|
| 2.1 | converge drops plugin state | **N/A** — repo-local files; `AGENT_POLICY_DESCRIPTORS` writes only `claude-home/settings.json` and `gemini-home/antigravity-cli/settings.json`, never `/workspace` |
| 2.2 | `npx -y` fetch at every launch | **N/A** — the binary is on disk |
| 2.3 | 42 skills / 4 agents / 3 hooks | **N/A** — plain MCP server, no plugin layer |
| 3.1 | pinned ~111 versions behind head | **N/A** — PyPI and Gate 3; the age gate applied cleanly at 0.10.0 |
| 3.2 | native `.node` addons vs `noexec` tmpfs | **N/A** — pure Python, in the workspace bind mount |
| 5 D3 | project `.mcp.json` route is "closed" | **WRONG, and the live setup is the proof.** `enabledMcpjsonServers` in a *repo's* `.claude/settings.local.json` is not the converged `settings.json`. The fal-ai server in `fluidmomenta/website` has survived every `up` on this shape (1975 `queue.fal.run` requests in that profile's Squid log, 2026-08-31) |

**§8 listed `comfy-cli` as a non-goal** — "a `[pypi]` + Gate 3 question of its
own… a separate item if it is ever wanted." It was wanted, and it was done,
through the right door, six days later. The non-goal was the answer.

**Do not implement D1(a)/(b) or D3(c).** No Dockerfile layer, no
`sandbox_templates/claude/claude-mcp.json`, no third descriptor row, no change
to the `"overwrite merge "` mode lock in `agent-policy.test.sh`.

## 4. Direction: stay on the PyPI package

Recorded from the companion doc's §5. The npm package's one advantage is
release velocity, and this sandbox is built to resist exactly that — age gate,
lockfile pinning, no launch-time fetch, converge wiping non-repo-local state.
The two native addons are a blocker independent of that argument.

## 5. Containment posture — egress-primary, ask rules deferred

**Owner decision, 2026-08-31.** `my_comfyui` is a learning and exploration
playground, not production. Domain-level egress control is the primary
containment: the download and control-plane sections stay closed most of the
time and are opened by hand for the span of a specific task. Per-tool `ask`
rules are judged not worth their friction at this scale.

That is a coherent position, and most of the blast radius genuinely does close
with the domains. What follows is only the part that does **not**, so the
accepted risk is accepted knowingly rather than by omission.

### 5.1 The tool surface has nothing to fall back on

39 tools, and **zero** `readOnlyHint` / `destructiveHint` annotations in
`comfy_mcp/server.py` (`requiresUserInteraction`: 0 occurrences). There are
also zero `mcp__` rules in `sandbox_templates/claude/claude-settings.json`
(58 allow, 8 ask, 96 deny — none MCP). So every call routes to the auto-mode
classifier with no signal.

Five tools advertise a confirmation in their own docstring —
`install_node` "runs third-party code, **asks first**",
`switch_comfyui_version` "**DESTRUCTIVE, asks first**". Reading the signatures,
those are ordinary model-supplied booleans:

```
install_node:            names, confirm_install, ctx
switch_comfyui_version:  version, confirm_switch, ctx
update_comfyui:          target, confirm_update_all, ctx
partner_generate:        model, params, confirm_spend, out_path, timeout_seconds, ctx
download_model:          url, relative_path, filename, wait, timeout_seconds
```

No confirmation token, no out-of-band handshake (`confirm` / `acknowledge` /
`yes_i_mean_it` as token mechanics: 0 hits). **The server asks the agent, and
the agent answers.** `download_model` has no confirm parameter at all.

And a rule could not see those parameters anyway: Claude Code **skips any
`mcp__` rule containing parentheses** and reports it in the invalid-settings
dialog and `claude doctor`, so MCP rules are whole-tool only. Globs are allowed
in the tool-name position for `ask`/`deny` (`mcp__comfy__*`), arguments are not.

### 5.2 Measured 2026-08-31 — the companion doc's three open items

Read from the installed source and live config on the host. **Nothing was run
and no container was touched.**

**(a) `install_node` and `update_comfyui` drive `pip` outside `with-egress.sh`.
CONFIRMED — this is the finding that egress does not cover.**
`comfy_cli/cmdline.py:653` runs `[python, "-m", "pip", "install", "-r",
"requirements.txt"]`; `comfy_cli/update.py:45` runs `[sys.executable, "-m",
"pip", "install", "-U", "comfy-cli"]`. `comfy_mcp/server.py:993` documents the
same thing from the caller's side ("`update` runs `git pull` and then a
multi-GB `pip install -r requirements.txt`"). `[pypi]` is **always-on**
(`proxy/allowed_domains.txt:319-322`), so those runs succeed today with **no
`UV_EXCLUDE_NEWER` age gate, no malicious-package preflight, no
`depgate.jsonl` entry, and no `requirements.lock` update**. The audit log is
not merely bypassed — it stays silent, which reads identically to a clean run.
Same shape as the under-reporting failure AGENTS.md names for `with-egress.sh`.
`node_dependencies` is genuinely read-only (no pip, no subprocess in its body).

**(b) Partner traffic is closed today.** The Comfy Org endpoints named in the
source are `api.comfy.org` (`cnr_utils.py` base_url), `registry.comfy.org`, and
`t.comfy.org` (telemetry, disabled by `enable_tracking = False`). The first two
sit commented in the `[comfyui]` block at `proxy/allowed_domains.txt:550-551`;
the third is not in the allowlist at all. So `partner_generate` 403s.
**This corrects the companion doc's §6 item 5** — spend *is* covered by egress,
provided `[comfyui]` stays shut. It is one uncommented line away from not being.

**(c) The Comfy Cloud credential store is plaintext and unguarded by the deny
list.** `comfy_cli/auth/__init__.py` documents
`${XDG_CONFIG_HOME}/comfy-cli/secrets.json`, mode 0600, **plaintext JSON**
("Phase 5 will replace this… with an encrypted `secrets.bin`" — not yet). The
`config` dir is a persistent bind mount (`docker-compose.yml:67`), so the
container path is `/root/.config/comfy-cli/secrets.json` and it outlives
`docker rm`. The claude deny list covers `/root/.config/gh/**` and
`/root/.config/glab-cli/**` but **has no comfy-cli entry**, and
`Read(**/.credentials*)` does not match `secrets.json`.
Currently harmless: only a 0-byte `secrets.json.lock` exists — `auth_login` has
never completed, so there is no credential to read.

### 5.3 What still bites with every download domain closed

From the companion doc §6, retained and narrowed by 5.2:

1. **Unaudited PyPI installs** — 5.2(a). The one item egress cannot reach.
2. **Environment divergence** — `switch_comfyui_version` / `update_comfyui`
   move the install out from under `requirements.lock` and `snapshots/`. For a
   playground whose value is reproducible learning steps, arguably more
   expensive than losing a workflow. Also breaks `comfy-mcp` itself if a shared
   dep (`pydantic`) is moved.
3. **In-flight work** — `stop_comfyui` / `restart_comfyui` kill a running
   queue. A `sweep-grid` run is hours of GPU, not a file.
4. **Local writes** — `upload_file` into the input/model dirs, no network.
5. **Disk** — `download_model` during a window that is legitimately open.

Items 2–5 are the accepted risk. Item 1 is the one worth a second look.

## 6. The two cheap things, if any of this is ever done

Both are egress-independent and neither costs a prompt in normal use. Neither is
required to leave this item parked.

**(a) One deny line**, matching the existing `gh` / `glab-cli` pattern in
`sandbox_templates/claude/claude-settings.json`:

```
"Read(/root/.config/comfy-cli/**)"
```

Zero friction (the agent has no reason to read it), closes 5.2(c) before
`auth_login` is ever run rather than after. Adding it requires
`bash scripts/agent-policy.test.sh`, which it should pass unchanged: the
two-way diff there compares `Bash(...)` entries only (`bash_entries` routes
everything else into an unused `c_other`), and the suite separately locks
antigravity's deny list to `command(...)` **only** — so this line correctly gets
no `agy` twin, and writing one as `read(...)` would be the failure that
assertion exists to catch.

**(b) Three ask rules**, if item 1 of §5.3 is judged not acceptable:

```json
"mcp__comfy__install_node",
"mcp__comfy__update_comfyui",
"mcp__comfy__switch_comfyui_version"
```

These three, and only these, are the ones that reach PyPI outside the audit log
and move the install out from under the lockfile. `partner_generate`,
`download_model` and `search_models` are left to egress deliberately, per §5.

**MCP rules are claude-only by construction.** `agent-policy.test.sh` diffs
only `Bash(...)` entries, so `mcp__` entries pass unnoticed in either direction;
and antigravity's permission vocabulary is locked to `command(...)`, so there is
no `agy` twin to write. If `agy` is ever pointed at `comfy-mcp` through
`gemini-home/config/mcp_config.json`, none of these apply and **nothing will say
so**. That gap should be asserted rather than left implicit.

**Before relying on either:** `_ask_note`'s "ask outranks the auto-mode
classifier" is measured for **Bash** (differential test, 2026-08-15,
`myclickup create --help`). For MCP tools it is inference from the docs. The
honest verification is the same shape: call a low-consequence gated tool
(`stop_comfyui` with ComfyUI already down) without the rule and with it, with
the rule as the only variable, and write the result into the note.

## 7. Unpark conditions

Any one of these makes this item live again:

- [ ] `[comfyui]`, `[comfyui-models]` or `[comfyui-models-extra]` moves from
      hand-opened windows to standing-open — the egress-primary posture in §5 is
      predicated on those being shut by default, and a standing-open section
      turns every deferred `ask` rule back into an open question
- [ ] `auth_login` is run — 5.2(c) stops being hypothetical the moment
      `secrets.json` has content
- [ ] `install_node` is wanted for real — 5.2(a) is the decision, not the tool
- [ ] `agy` is pointed at `comfy-mcp` — §6's coverage gap becomes live
- [ ] A named capability in the npm package's 42 skills that comfy-cli cannot
      reach. The case today is cadence, not function, and cadence is not a
      reason to move

## 8. Unverified — do not present these as fact

- Whether an `ask` rule outranks the auto-mode classifier for **MCP tools**
  (§6). Measured for Bash only.
- Whether `api.comfy.org` is the endpoint `partner_generate` itself calls, or
  only the registry base URL. Both are in the same closed block, so the
  conclusion in 5.2(b) holds either way, but the attribution is from a source
  read, not a traced request.
- Whether a `claude.json` `mcpServers` entry needs a trust prompt in an attached
  container. Moot while the project `.mcp.json` route is the one in use.
- The original §9's npm-specific items (what `--full` enables, the real tree
  size, whether the server starts with `better-sqlite3`'s postinstall blocked).
  Dead with the npm direction; kept here only so a future reader does not
  re-open them thinking they were dropped by accident.

## 9. Non-goals

- Installing `comfyui-mcp` (npm), the `comfy` plugin, or any of its 42 skills /
  4 agents / 3 hooks.
- Any `Dockerfile` change — the package is repo-local by design.
- Any `AGENT_POLICY_DESCRIPTORS` change or `claude-mcp.json` template.
- Opening `[comfyui]`, `[comfyui-models]` or `[comfyui-models-extra]` on a
  standing basis. Hand-opened task windows are the current posture (§5).
- Publishing port 8188. VS Code's tunnel already forwards it.

## 10. Security note

Carried from the original §7, with what changed:

- **The upstream-authored package is the tighter of the two**, and the pinned,
  age-gated, lockfile-recorded install is tighter still than `npx -y` resolving
  head at every session start. That argument stands; it just landed on a
  different package than this spec expected.
- **It is still third-party code inside the boundary, beside agent
  credentials** — same posture point 0016 §7(3) makes about Manager's custom
  nodes. Upstream authorship narrows the supply chain; it does not remove it.
- **It hands the agent actions 0016 deliberately left to a human**: install node
  packs, download weights, restart the process. Under the current allowlist most
  of those 403. §5 records that this containment is a hand-managed window, not a
  policy, and accepts it.
- **`comfy-cli`'s own `pip` path is outside the audit log** (5.2(a)). That is
  new since the original spec and is the one place the egress-primary posture
  has a hole rather than a cost.
- **0016 §7(4) is untouched and still true.** The ComfyUI web UI's own egress
  leaves via the operator's browser, outside the container, unseen by
  `access.log`. An MCP server changes nothing about that boundary.
