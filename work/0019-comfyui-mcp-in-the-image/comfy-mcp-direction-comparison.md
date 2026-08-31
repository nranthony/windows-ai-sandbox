# ComfyUI MCP — direction comparison and decision record

**Status:** informational / decision pending
**Scope:** sandbox ComfyUI playground (`~/repo/nranthony/my_comfyui`)
**Supersedes discussion in:** spec 0019
**Related:** 0020 (genmedia spend tier), §6.5

---

## 1. Summary

Two candidate MCP servers were under consideration. They are not two versions of one project — they are different packages in different ecosystems whose names differ by one character. Spec 0019 was written against the npm package; the package actually installed is the PyPI one.

| | 0019's subject | What is running |
|---|---|---|
| Package | `comfyui-mcp` (npm) | `comfy-mcp` 0.10.0 (PyPI) |
| Author | artokun, third-party | Comfy Org (upstream) |
| Description | — | MCP server for ComfyUI, thin wrapper over comfy-cli |
| Runtime deps | 10, two native (`better-sqlite3`, `sharp`) | 3: `mcp`, `pydantic`, `anyio` |
| Cadence | 454 releases in 6 months | 0.10.0 |
| Lives in | proposed: baked into the image | `.venv`, pinned in `requirements.lock` |

---

## 2. Current state — `comfy-mcp` (PyPI)

Registered in `.mcp.json` from the workspace venv:

```json
{"mcpServers": {"comfy": {
  "command": "/workspace/my_comfyui/.venv/bin/comfy-mcp",
  "env": {"COMFY_BIN": "/workspace/my_comfyui/.venv/bin/comfy"}}}}
```

Enabled via `.claude/settings.local.json` → `enabledMcpjsonServers: ["comfy"]`.
`.mcp.json` is tracked; `settings.local.json` is gitignored.

### Install provenance

`audit/depgate.jsonl`, 2026-08-29, entry 27 — `uv pip install "comfy-cli>=1.14.0" comfy-mcp`:

- `sections: ["pypi"]`, `denied: []`, `rc: 0`
- `py_age_gate: {applied: true, exclude_newer: "2026-08-22T19:04:16Z", window_days: 7}` — held, no `--allow-fresh`
- preflight: both packages `NO-KNOWN-MAL`

Went through `with-egress.sh` exactly as designed. Landed `comfy-cli==1.17.0` + `comfy-mcp==0.10.0`, both pinned in `requirements.lock`.

### Pros

- Upstream-authored, so the tool surface tracks comfy-cli by construction rather than by a third party's reverse-engineering.
- Three pure-Python deps. Nothing to compile, nothing that collides with a noexec tmpfs.
- Clean, audited install through the intended door.
- Repo-local. Converge does not touch it; `AGENT_POLICY_DESCRIPTORS` never reaches `/workspace`, so state survives.
- Binary is on disk — no fetch on the launch path.

### Cons

- Thin. It is comfy-cli surface and little more. No skills, agents, or hooks layer.
- Slow cadence; new capability waits on upstream.
- 38 tools with zero annotations (`readOnlyHint` / `destructiveHint` unset in `comfy_mcp/server.py`) and zero `mcp__` rules in `sandbox_templates/claude/claude-settings.json` (58 allow, 8 ask, 96 deny, none MCP). Everything routes to the classifier under `defaultMode: auto` with nothing to go on. This is a property of the local config, not the package. See §5.

---

## 3. Candidate — `comfyui-mcp` (npm)

### Pros

- Much more active: 454 releases in six months against a single 0.10.0.
- The plugin layer (42 skills, 4 agents, 3 hooks) is genuine added surface if those are things that would otherwise be written by hand.

### Cons

- Two native addons (`better-sqlite3`, `sharp`) want to execute compiled binaries — a direct conflict with noexec tmpfs, not a tunable preference.
- `npx -y` at every launch is an unpinned network fetch on the startup path, defeating the lockfile and the egress gate simultaneously.
- High cadence works against the age gate. With a 7-day `exclude_newer` window that is roughly 18 releases behind on every pull; 0019 already found the proposed pin sitting 111 versions back. Permanent staleness plus recurring gate friction.
- The plugin layer does not survive converge (0019 §2.1).
- Third-party authorship on a package one character from the upstream name is its own supply-chain consideration.
- Baked into the image means not repo-local and not visible in `requirements.lock`.

---

## 4. Disposition of spec 0019

Every objection in 0019 was raised against the npm package. None survives contact with what is actually installed:

| 0019 | Objection | Status |
|---|---|---|
| §2.1 | converge drops plugin state | N/A — repo-local files; `AGENT_POLICY_DESCRIPTORS` never touches `/workspace` |
| §2.2 | `npx -y` at every launch | N/A — binary on disk |
| §2.3 | 42 skills / 4 agents / 3 hooks | N/A — plain MCP server, no plugin layer |
| §3.1 | pinned 111 versions behind | N/A — PyPI and Gate 3, gate applied cleanly |
| §3.2 | native `.node` addons vs noexec tmpfs | N/A — pure Python in the workspace mount |

0019 §8 listed comfy-cli as a non-goal — a `[pypi]` + Gate 3 question of its own, a separate item if ever wanted. It was wanted, and it was done, through the right door.

**Recommendation:** 0019 does not need implementing. Rewrite it as a record of what shipped, or close it with a pointer to this document.

---

## 5. Transition decision

**Recommendation: do not transition at this time.**

The npm package's single advantage is release velocity, and this sandbox is built to resist exactly that — age gate, lockfile pinning, no launch-time fetch, converge wiping non-repo-local state. The two native addons are a blocker independent of everything else.

Revisit if any of the following change:

- [ ] Native deps removed, or an exec-permitted mount is accepted for them
- [ ] A pinned install path exists that is not `npx -y`
- [ ] The plugin layer becomes repo-local so converge stops eating it
- [ ] A specific capability in the 42 skills is named that comfy-cli cannot reach — the case today is cadence, not function

---

## 6. Ask rules (§6.5) — accepted risk

**Decision:** ask rules deferred. This is a learning/exploration playground, not production ComfyUI. Domain-level egress control is treated as the primary containment, and the productivity cost of prompting on every action tool is judged not worth it at this scale.

### Residual blast radius with download domains blocked

The working assumption under review was that workflow files are the only thing at risk once download domains are closed. That is too narrow. The following do not require the HuggingFace domains and are therefore unaffected by closing them:

1. **In-flight work.** `stop_comfyui` / `restart_comfyui` kill a running queue. Loss is anything queued or generating and not yet written out, not just saved workflow files.
2. **Environment divergence.** `switch_comfyui_version` / `update_comfyui` move the version out from under `requirements.lock`. The lockfile silently stops describing the environment. For a playground whose value is reproducible learning steps, this is arguably the more expensive failure than losing a workflow.
3. **Unaudited packages via a different open door.** `node_dependencies` (and `install_node` if `[comfyui]` is ever opened) may invoke pip through comfy-cli directly rather than through `with-egress.sh`. `[pypi]` is open — that is how comfy-mcp was installed. If that path exists, packages land in the venv without the age gate, preflight, or a lockfile entry. **Verify this before relying on domain blocking alone.**
4. **Venv breakage.** The same path can upgrade or downgrade shared deps (`pydantic`, etc.) and break both the MCP server and ComfyUI.
5. **Paid spend.** `partner_generate` / `list_partner_models` / `partner_model_schema` hit Comfy Org partner endpoints, **not** HuggingFace. Blocking `huggingface.co` and `us.aws.cdn.hf.co` does not close this. This is the same spend surface 0020 put on the ask tier for genmedia. **Confirm which domain partner traffic uses and whether it is currently open.**
6. **Local writes.** `upload_file` writes into input/model directories with no network involvement — overwrite risk.
7. **Credential material.** `auth_login` writes credentials to disk. Worth confirming the write location is not tracked or synced.
8. **Disk.** `download_model` when a domain is legitimately open — large files, fill risk.

### Live gap today

`install_node` 403s only because the `[comfyui]` control plane is closed. But `huggingface.co` and `us.aws.cdn.hf.co` are uncommented in the working tree right now, so `download_model` and `search_models` are live and unprompted.

Because egress sections are opened and closed by hand as work proceeds, containment on those tools is the state of an uncommitted file rather than a policy — and the window in which a domain is open is exactly the window in which the tools are being used. `_ask_note` in the template already records the measured behaviour: absence of a rule alone does not produce a prompt.

### Cheaper middle option

Rather than 15 ask rules, three or four cover the items above that egress cannot reach:

- `mcp__comfy__partner_generate` → ask (spend, different domain)
- `mcp__comfy__switch_comfyui_version`, `mcp__comfy__update_comfyui` → ask (lockfile divergence)
- `mcp__comfy__node_dependencies` → ask (unaudited PyPI path), pending verification of item 3

Read tools stay on auto. This is cheap enough that it should not register as friction.

---

## 7. Open items

- [ ] Verify whether `node_dependencies` / `install_node` invoke pip outside `with-egress.sh`
- [ ] Identify the partner API domain and its current egress status
- [ ] Confirm `auth_login` credential write location
- [ ] Rewrite or close 0019
- [ ] Decide on the three-rule subset in §6
