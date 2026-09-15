# 0029 — Proxmox-comparison hardening: close the egress and credential gaps a VM review surfaced

**Status: Draft** — opened 2026-09-15. Triggered by a design review of a
proposed Proxmox VE sandbox (isolated VLAN, dedicated admin NIC, pfSense +
pfBlockerNG, blank VM). The review concluded that a VM adds a stronger escape
boundary than this stack has but nothing at the agent-policy layer, and that
this stack's own remaining gaps are the same class the VM review found:
**allowed egress that doubles as an exfil channel, and secrets sitting where
the agent can read them.** This item is the resulting backlog for this repo.
Sibling item: `macolima@work/0012-proxmox-comp-hardening`.

**Cross-refs:** [SECURITY_ASSESSMENT.md](../../SECURITY_ASSESSMENT.md) (rec. 1
"restrict config access" is still open; rec. 2 docker socket is CLOSED — the
socket is no longer mounted, verified 2026-09-14);
[web-read-broker.md](../../docs/web-read-broker.md) (§1 finding below is the
half its threat statement misses); [ADR-0003](../../docs/adr/0003-strict-egress-default.md)
(strict egress — the principle §1 extends to the reader services);
[0025](../0025-notice-says-registries-closed-and-pypi-is-open/spec.md)
(WebFetch scoping unrealised — folded into §5 here);
[0027](../0027-admin-profile/spec.md) (the relay in §2 is the natural place the
admin profile's push credential lives too).

---

## 1. The threat model this item is written against

Not a compromised server phoning home. The adversary is **prompt injection**
— a README, a fetched page, an issue, a package — steering the agent to use
its *legitimate* tools and *allowlisted* egress. Every finding below is a path
that works with zero escapes and zero firewall bypasses. The controls this
repo already has (internal network, Squid allowlist, DNS sinkhole, seccomp,
cap_drop, deny lists, hook engine, dependency gates) are all sound against
that adversary; what follows is what they do not yet cover.

## 2. Findings, as measured 2026-09-14 against this tree

| # | Finding | Evidence | Class |
|---|---|---|---|
| F1 | **Allowlisted fetch-on-behalf services are an exfil channel.** `r.jina.ai` takes the target URL in its *path*; Tavily, Firecrawl and TinyFish take it in a POST body. Each will fetch `https://attacker.example/?d=<payload>` from *its* infrastructure, through our allowlist, and the destination logs the payload. | `proxy/allowed_domains.txt` (jina, tavily, firecrawl, tinyfish rows); `docs/web-read-broker.md` says "every domain added to the allowlist is also a place the agent could POST to" — true, and this is the other half: a place that will GET anywhere *for* you | egress |
| F2 | **Write surfaces on the allowlist that no current profile needs always-on.** `openrouter.ai`, `api.openai.com`, `api.smith.langchain.com`, `generativelanguage.googleapis.com`, `fal.run` / `queue.fal.run` / `.fal.media` (wildcard). Each is a key plus a POST target. | `proxy/allowed_domains.txt` | egress |
| F3 | **Secrets are readable by the agent.** `/root/.claude/.credentials.json`, `/root/.config/gh/hosts.yml`, `/root/.gemini/*`, `/root/.claude.json`, and every key in `secrets.env` (process env). The `Read(...)` deny rules cover the Read tool only; the hook states "credential denials live in permissions.deny" and adds no Bash-side rule, so `cat`, `printenv` or a Python *file* (not `-c`) reading `os.environ` passes both layers. | `sandbox_templates/claude/claude-settings.json` deny list; `sandbox_templates/claude/hooks/deny-destructive.sh:275`; `docker-compose.yml:61-81` (bind mounts), `:136` (secrets.env) | secrets |
| F4 | **GitHub token has default scopes.** `setup.sh` runs `gh auth login` with no `--scopes`, so the token carries gh's defaults, which include `gist`. `api.github.com` is allowlisted. One `gh gist create` — or the raw API from a script, since `gh` is denied by prefix only — is an exfil path, and `repo` scope reaches every repository the account owns. | `scripts/setup.sh:141-143`; `proxy/allowed_domains.txt` (`api.github.com`) | secrets |
| F5 | **`WebFetch` is unlisted, not denied.** Under `defaultMode: auto` an unlisted tool goes to the classifier, whose behaviour this repo's own notes describe as unspecified and unpinned. `WebFetch` executes from Anthropic's infrastructure and bypasses Squid entirely. | `claude-settings.json` `_webfetch_note`; 0025 §1 | policy |
| F6 | **`disableBypassPermissionsMode` and `enableAllProjectMcpServers` are unset.** `--dangerously-skip-permissions` is therefore available inside a profile, and project `.mcp.json` handling rests on the default prompt. Behaviour of a *cloned repo's* `.claude/settings.json` hooks at trust time is **unmeasured** here. | grep over `sandbox_templates/` returns neither key | policy |
| F7 | **Squid access log is tmpfs and dies with the container.** It is the only record of what left the sandbox. | `docker-compose.yml:351`; SECURITY_ASSESSMENT.md already notes it | audit |
| F8 | **Plaintext HTTP and unbounded request bodies.** Squid allows port 80 to allowlisted domains and sets no `request_body_max_size`. | `proxy/squid.conf:29-37` | egress |
| F9 | **Agent runs as container root.** Host UID 1000 under rootless Docker, so the *host* boundary holds — but the hook comment concedes the Bash/Edit tamper rules are the only protection on the hook script itself. macolima runs a non-root `agent` (UID 1000) with the script root-owned, making tampering a kernel decision. | `Dockerfile:827` (`USER root`); `claude-settings.json` `_hooks_comment` | policy |
| F10 | **GPU overlay is auto-applied on detection.** `/dev/dxg` plus `/usr/lib/wsl` expose the WSL paravirtualised GPU driver to every container on this substrate, whether or not the profile does ML. | `ARCHITECTURE.md` "auto-detected by `scripts/profile.sh`"; `docker-compose.wsl-gpu.yml` | surface |

Verified NOT open (so the plan does not repeat them): docker socket mount
(gone); DNS exfil (sinkholed + `extra_hosts`); registries (ADR-0003 window,
age gate, wheels-only); `curl`/`wget`/`nc` (denied — a speed bump, and known
to be one; the allowlist is the control, which is why F1/F2 matter).

## 3. The one move that changes the model: a credential relay

F1's payload, F3 and F4 collapse together if **no secret is present in the
agent container**. Claude Code already supports `ANTHROPIC_BASE_URL`, and
`profile.sh <p> backend` already manages a `backend.env` that sets it (0023
§8). Point it at a small relay sidecar on `sandbox-internal` that holds the
real Anthropic credential and injects it; do the same for GitHub with the git
remote pointed through the relay and the token injected there. Squid cannot do
this — it sees only CONNECT tunnels — so it is a second, tiny HTTP container,
not a Squid rule. Once done, `cat .credentials.json` returns nothing worth
having, `hosts.yml` does not exist in the agent, and the reader-service keys
live beside the URL allowlist that gates them (§4 D1 option b).

## 4. Decision gates (owner)

- **D1 — F1, reader services.** (a) Drop them and accept a narrower web; or
  (b) move the `webfetch` broker out of the agent container into the relay
  sidecar, which holds the keys and enforces a **destination-domain allowlist
  on the URL it is asked to fetch** before forwarding. (b) keeps the feature
  and closes the hole; (a) is one commit. Recommendation: (b), because the
  broker is already a stdlib script with its own 90-case suite.
- **D2 — Relay scope.** Anthropic only first (one profile, `backend.env`
  switch, measurable in an hour), or Anthropic + GitHub together. Recommendation:
  Anthropic first; GitHub follows once the pattern is proven, since it also
  changes how remotes are written in every workspace.
- **D3 — F4 interim.** Until the GitHub half of D2 lands: re-issue the token as
  a **fine-grained PAT per profile** (that profile's repos only; contents +
  pull-requests; no gist) via `gh auth login --with-token`, and protect `main`
  on the target repos so the agent can only open PRs. This is a host-side
  action and needs no code.
- **D4 — F9.** Adopt macolima's non-root `agent` user (Dockerfile pattern
  exists; every `/root/...` mount and template path moves to `/home/agent`),
  or record the current posture as accepted. This is the largest diff in the
  item and touches every profile's persisted state paths; it can ship last.
- **D5 — F10.** Make the GPU overlay opt-in per profile (a `gpu` flag next to
  `db enable` / `ollama enable`) rather than substrate-detected.

## 5. Out of scope

A Proxmox substrate for this stack. `ARCHITECTURE.md` already defines bare
Ubuntu + rootless Docker as substrate B, and that is the path if a VM is ever
wanted; nothing in this item depends on it.
