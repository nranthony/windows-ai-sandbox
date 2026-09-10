# 0024 — Alpha test: Claude Code on the Ollama sibling and on OpenRouter

**Status: Draft** — opened 2026-09-04 as the follow-on to
[0023](../../docs/_archive/0023-ollama-sibling-container-spec.md). 0023 shipped the
*mechanism* (sibling, shared read-only store, `profile.sh <p> backend …`);
this item is the *use* of it: does Claude Code actually do useful work on a
non-Anthropic endpoint inside this sandbox, and what does the switch cost in
practice. Nothing here changes the boundary; everything here is measurement.

**Branch:** `feat/0023-ollama-sibling` (four commits, unmerged as of opening).

---

## 1. What is already proven (do not re-measure)

From [0023 notes.md](../../docs/_archive/0023-ollama-sibling-container-notes.md), 2026-09-03:

| Claim | Evidence |
|---|---|
| Sibling is air-gapped | no default route, no proxy vars, phone-home attempts die |
| GPU is used | `library=CUDA … RTX 3080 Ti` in the sibling log; KV cache on CUDA0 |
| Store is read-only to the API | `/api/delete`, `/api/create` → EROFS from the agent |
| Agent reaches it direct | `/api/version` via NO_PROXY; DNS sinkhole intact |
| Claude Code round-trips | `claude -p` against `qwen3:0.6b`: four `POST /v1/messages 200` |
| count_tokens does not wedge 0.33.3 | 404, server alive after |
| Stale agent is caught | `verify` fails on NO_PROXY until recreate |
| `backend` command | every branch exercised under a fake HOME; compose injection order confirmed |

## 2. What is NOT proven — the alpha

Everything below was either run with a toy model or not run at all.

1. **A real coding session on a real local model.** Only `qwen3:0.6b` has been
   driven, with a one-line prompt. Nothing has edited a file, run a tool, or
   used a subagent on the sibling.
2. **The recreate path end to end.** `--recreate` was never run against a
   live profile (the nranthony agent had a VS Code attach). The pending-
   recreate warning was seen; the transition itself was not.
3. **OpenRouter at all.** No key in any profile; `backend openrouter` was
   exercised only with a fake key under a fake HOME. Squid's handling of the
   Anthropic-skin endpoint is unmeasured.
4. **Tool calling quality.** The community figure (70–80 % edit accuracy on
   local models vs ~98 % Sonnet) is someone else's measurement on someone
   else's repos.
5. **The hook engine under a non-Anthropic model.** The guardrails are on the
   harness, so they *should* fire identically. "Should" is not a measurement:
   a weaker model may phrase a denied command differently, and the ask tier's
   headless-deny behaviour has only been measured on Anthropic models.
6. **Context handling.** The sibling now sets `OLLAMA_CONTEXT_LENGTH=32768`;
   Claude Code assumes 200k for an unrecognised model unless `--context` is
   passed. What happens at the 32K edge — silent truncation, an error, or
   auto-compact — is unknown.
7. **VRAM behaviour across profiles.** One sibling has run at a time. Two
   profiles with siblings, or a sibling beside a ComfyUI run in the agent,
   has not been tried on the 12 GB card.
8. **MCP tool search off.** Documented consequence of a non-first-party base
   URL; not observed. Which MCPs in a profile become invisible?
9. **`verify` on a recreated agent.** The backend check has only ever seen the
   default branch on a live agent.

## 3. Test plan

Run on **`nranthony`** (has the sibling enabled and two toy models pulled) at
a moment when dropping the VS Code attach is acceptable. Record every result
in `notes.md`; each row in §2 gets a line.

### 3.1 Local model, real work
```bash
just ollama nranthony pull qwen3-coder          # ~18 GB on disk; 30B-A3B, fits 12 GB at q4 with 32K ctx? MEASURE
just backend nranthony ollama --model qwen3-coder --context 32768 --recreate
just verify nranthony                          # expect: backend ollama sibling, NO_PROXY ok, sibling answers
```
Then inside the container, in a scratch repo under `/workspace`:
- one file edit via Claude Code (Edit tool) — does the model produce a valid tool call?
- one Bash tool call the hook DENIES (`rm -rf /tmp/x`) — reason returned, not executed?
- one ASK-tier call (`git rm <file>`) headless via `claude -p` — denied with reason?
- one subagent spawn — does it run on the same base URL? (`docker logs ollama-nranthony` shows the POSTs)
- `nvidia-smi` on the host during and 6 minutes after — keep-alive releases VRAM?
- push a long transcript past 32K — what does the user see?

If `qwen3-coder` does not fit, fall back to `qwen2.5-coder:14b` or `gpt-oss:20b`
and say which. Record `ollama ps` output (size, processor split).

### 3.2 OpenRouter
```bash
# once: OPENROUTER_API_KEY=sk-or-v1-... in ~/.ai-sandbox/profiles/nranthony/secrets.env
just backend nranthony openrouter --model anthropic/claude-sonnet-4.5 --recreate
just verify nranthony                          # expect WARN naming the https host (by design)
```
- same three tool-call probes as §3.1
- Squid access.log: `CONNECT openrouter.ai:443` and nothing else new
- confirm the token is in the `Authorization` header, not the URL (Squid logs URLs)
- try a non-Anthropic model id through OpenRouter (e.g. `deepseek/deepseek-v3`) —
  does the Anthropic skin pass tool use through? This is the actual point of
  OpenRouter here.

### 3.3 Back to default, and the audit
```bash
just backend nranthony anthropic --recreate
just verify nranthony && just audit nranthony
```
Audit must show zero DRIFT after the round trip.

## 4. Decision gates (answer from §3 evidence, not from the write-ups)

- **D1 — Is the local path worth keeping on by default for any profile?**
  If tool-call accuracy on a real edit is below what you would accept from a
  junior, the sibling is an embeddings/summarisation service, not a Claude
  Code backend, and the docs should say so.
- **D2 — Does the hook engine need a rule change for weaker models?** Only if
  §3.1 shows a denied verb reaching execution through a phrasing the
  normaliser does not see. That would be a hook change with the 207-case
  suite, not a backend change.
- **D3 — Router sibling (mix OpenRouter planner + Ollama workers)?** Opens
  only if D1 says local is good enough for *some* role. Otherwise the
  question is moot and the OpenCode/Goose route in the 2026-09-03 discussion
  stays the alternative.
- **D4 — Seccomp on the sibling.** Independent of the above: try
  `seccomp=./seccomp.json` on `ollama-<p>` in a scratch run and record which
  syscalls (if any) it denies. A pass closes the one "default seccomp"
  carve-out in 0023 §2.7.

## 5. Out of scope

- Any change to the allowlist, the hook engine, or the sibling's hardening
  except as a *result* of D2/D4.
- Antigravity against Ollama (no documented base-URL switch).
- Merging the branch — that is 0023's exit, and it can merge before this item
  runs; the mechanism does not depend on the alpha's outcome.

**Exit rule:** archive to `docs/_archive/` with `notes.md` when D1–D4 are answered.
