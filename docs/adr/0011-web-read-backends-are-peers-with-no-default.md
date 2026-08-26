# ADR-0011 — Web-read backends are peers with no default

- **Status:** Accepted (2026-08-26)
- **Date:** 2026-08-26
- **Affects:** `sandbox_templates/bin/webfetch` (`--via` required; `backends`
  subcommand), `scripts/webfetch.test.sh`, `sandbox_templates/skills/web-read/SKILL.md`,
  `sandbox_templates/common/agent-notice.md` (deployed into every consumer
  repo's `AGENTS.md` and every profile's global `CLAUDE.md`),
  `proxy/allowed_domains.txt` (`[web-read]` block comment),
  `docs/web-read-broker.md`.
- **Related:** [ADR-0003](0003-strict-egress-default.md) (why the agent reads
  the web through brokers at all — the registries and the open web are
  unreachable by default).

## Context

The restricted agent cannot fetch web pages itself: `curl`/`wget` are denied,
the real `WebFetch` tool is scoped per repo, and Squid admits only the hosts in
`proxy/allowed_domains.txt`. It reads the web through `webfetch`, a broker in
front of hosted reader APIs — Tavily, TinyFish, Jina, Firecrawl as of this
date — each of which does the arbitrary-URL egress from its own infrastructure
and returns clean text (`docs/web-read-broker.md`).

Until 2026-08-26 the broker had a built-in default: `--via` was optional and
resolved to `tavily`. The skill, the notice and the broker doc all showed the
`--via`-less form, so in practice every agent read went to one vendor.

That vendor has a quota. On 2026-08-20 a profile hit Tavily's HTTP 432
(quota exhausted) in the middle of a research task, and the failure was
recorded upstream as "attempted via the `webfetch` broker: Tavily quota
exhausted" — i.e. as *the web being unavailable*, not as *one of several
readers being unavailable*. Firecrawl was allowlisted and wired at the time.
Nothing told the agent to try it, because nothing in the tool or its guidance
presented the backends as alternatives to each other; they were "the default"
and "some other options behind a flag".

The same shape recurs with any single default: a vendor outage, a rotated key,
a rate limit, an API change, or a host dropped from the allowlist all read as
"can't read the web" when the truth is "can't read the web *this way*". The
agent-notice's standing instruction — treat a denial as a human step, do not
hunt for a workaround — makes this worse in exactly this case, because
switching reader is not a workaround, it is the intended use of having more
than one.

## Decision

**The web-read backends are peers. The broker has no default backend, the
agent chooses one explicitly, and a failure on one backend is a reason to
choose another — not a reason to stop.**

Concretely:

1. `--via` is **required** on `webfetch extract` and `webfetch search`. There is
   no `default=` on either flag; the test suite asserts its absence and that a
   `--via`-less call exits 2 without making a request.
2. `webfetch backends` lists every backend with the operations it supports and
   whether it is usable in *this* profile (`ready` / `NO KEY (VAR unset) — pick
   another` / `ready keyless`). It reports key **presence** only, never a value
   or prefix. This is what the agent consults before choosing.
3. The guidance the agent actually reads — the web-read skill and the sandbox
   notice — states the cycle rule in one sentence: any failure exit (3 missing
   key, 4 unreachable host, 5 upstream error, 6 nothing fetched) on one backend
   means **switch backend**; only when **every** backend has failed is the read
   blocked, and *that* is reported as a human step, with the exit codes.
4. The allowlist's `[web-read]` block lists backends in arrival order and says
   so. No entry is annotated as the default, primary, or preferred.

The backends remain **peers in capability class**, not in feature set: Tavily
and TinyFish do search + extract, Jina does both (keyless, rate-limited),
Firecrawl does extract only. "Peer" means no backend is privileged by the tool;
the agent still picks the one whose features fit the task.

## Consequences

- **One vendor's bad day is no longer the sandbox's bad day.** A quota wall,
  outage or key rotation on any single backend degrades the broker to the
  remaining backends instead of to nothing. This is the entire point.
- **Every call names its backend.** `webfetch extract <url>` without `--via`
  is now an error. Every example in the skill, notice and doc carries
  `--via <b>`; a consumer-repo instruction still showing the old form is
  stale and will fail loudly rather than silently route to one vendor.
- **The agent makes a choice it did not make before.** That is deliberate: the
  choice is cheap (`webfetch backends` is one call, no network) and the
  alternative — the tool choosing for it — is what produced the 432 incident.
- **Cycling is bounded by the allowlist, not by the agent.** The agent can
  only cycle among backends whose hosts are live in `[web-read]`; it cannot
  reach a new one by trying. Adding a backend is the documented procedure in
  that block (broker → exact host → secrets template), and the suite requires
  every host the broker names to be a live line, so a backend cannot be
  half-added.
- **The notice's "denial is a human step" rule is unchanged** for everything
  else. A TCP_DENIED on a *target* site is still not something to route
  around; a failure on a *reader* is what the other readers are for. The
  notice now draws that line explicitly.
- **Re-introducing a default is a reversal of this ADR**, not a convenience
  tweak. If a future maintainer wants one (say, to spare the agent the choice),
  the argument has to answer the 432 case: what tells the agent to move on
  when the default fails?

## Alternatives considered

- **Keep the default, make the broker fall through automatically** (try
  Tavily, then TinyFish, then …). Rejected. It hides which vendor served a
  read — the untrusted-content banner names the source, and a silent
  fallthrough would make the audit trail say one thing and the egress log
  another. It also bakes an ordering into the tool that the operator did not
  choose and cannot see, and the repo's standing rule is no fallback paths
  unless requested. The agent doing the cycling keeps every hop visible in the
  transcript.
- **Keep the default and document "try `--via` if it fails".** Rejected on
  the evidence: that documentation existed (the backends table with `--via`)
  and the 432 was still reported as the web being down. A default that works
  most of the time trains the reader to stop reading at the default.
- **Pick a "better" default (TinyFish, free tier, no quota wall).** Rejected
  for the same reason — it moves the single point of failure, it does not
  remove it. TinyFish has no wallet gate today; it has an API that can change.
- **Let the operator set a default per profile** (env var). Rejected as
  premature: it re-creates the single path per profile, and nothing has asked
  for it. It can be added later without touching this decision if a real
  need appears; it would need the same "what happens when it fails" answer.

## Not decided here

The companion rule that emerged in the same work — a broker vendor gets its
**read** hosts only, even when the same key unlocks a write surface (TinyFish's
Agent/Browser APIs; the Apify and Bright Data assessments reused the test) —
is recorded separately as
[ADR-0012](0012-web-read-backends-get-read-hosts-only.md). It is not folded
into this one because it is a different decision with a different failure
mode (exfiltration, not availability).
