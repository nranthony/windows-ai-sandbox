# ADR-0012 — Web-read backends get their read hosts only

- **Status:** Accepted (2026-08-26)
- **Date:** 2026-08-26
- **Affects:** `proxy/allowed_domains.txt` (`[web-read]` block — the boundary),
  `sandbox_templates/bin/webfetch` (which hosts the broker may call),
  `scripts/webfetch.test.sh` (the lock), `sandbox_templates/common/secrets.env.template`
  (what a stored key is and is not for), `docs/web-read-broker.md`.
- **Related:** [ADR-0003](0003-strict-egress-default.md) (strict egress —
  every allowlisted host is a deliberate act), [ADR-0011](0011-web-read-backends-are-peers-with-no-default.md)
  (the availability half of the same work; this is the exfiltration half).

## Context

The agent reads the web through `webfetch`, a broker in front of hosted reader
APIs. The design bargain is stated in `docs/web-read-broker.md`: the vendor
does the arbitrary-URL fetch from *its* infrastructure and returns text, so the
sandbox admits **one exact API host** per reader instead of the open web. The
cost is also stated: every admitted host is a place the agent can POST to, so
each backend is one more exfiltration channel, accepted because the channel's
only function is "give me this page".

That bargain assumes the admitted host *is* a reader — that the worst it can do
on the agent's behalf is fetch. Two things in 2026-08 showed the assumption has
to be enforced, not assumed:

1. **TinyFish** sells four APIs behind one key: Search and Fetch (readers), and
   Agent and Browser — a cloud browser the caller drives (logins, form-fills,
   arbitrary POSTs to arbitrary sites), plus an MCP server that exposes all four
   to a coding agent. The vendor's own onboarding is `npx -y @tiny-fish/cli
   connect --all`, which registers that MCP in every agent config it finds. The
   one-line allowlist entry `.tinyfish.ai` would have made every one of those
   reachable with the key we store for reading. A reader would have become a
   remote hand.
2. The **Apify / ScraperAPI / Bright Data / Crawlee** assessment (2026-08-26)
   turned on the same question. Apify's reader actor lives on its own hostname
   (`rag-web-browser.apify.actor`) while the arbitrary-code platform is on
   `api.apify.com`, so the reader can be admitted alone. ScraperAPI and Bright
   Data pass POST/PUT through to the target site and put the whole product
   behind one host, so admitting the reader admits the proxy. Crawlee is a local
   library — the egress would happen *inside* the boundary, which is not a
   broker at all.

The pattern: a vendor's **read** surface and its **act** surface often share a
key, a parent domain, or a host. The allowlist is the only layer that can tell
them apart, because a key cannot (the same key unlocks both) and the hook
cannot (an MCP or HTTPS call is not a Bash prefix).

## Decision

**A web-read backend is admitted for its read interface only. The allowlist
carries the exact host(s) of the fetch/search API and nothing else from that
vendor, and it says which sibling hosts were deliberately left out.**

Concretely, a backend qualifies only if all of the following hold:

1. **Vendor-side egress.** The arbitrary-URL fetch happens on the vendor's
   infrastructure. A library that fetches from inside the container (crawl4ai,
   Crawlee) is not a backend, however good its output.
2. **Exact host, never a wildcard.** `api.search.tinyfish.ai`, not
   `.tinyfish.ai`. If the vendor's read API and act API share one host, the
   vendor does not qualify (Bright Data's `api.brightdata.com`, ScraperAPI's
   proxy mode) — there is no allowlist line that admits one and not the other.
3. **Key in a header, never the URL.** Squid logs URLs; a key in a query string
   is a leak the agent cannot see. ScraperAPI's `?api_key=` form disqualifies
   it on its own.
4. **No passthrough of the agent's request to the target.** The backend takes
   a URL and returns text. A backend that forwards the agent's POST body, method
   or headers to the target site is a proxy, not a reader.
5. **Write-surface siblings are named and excluded.** When the same key or
   parent domain also unlocks an agent/browser/automation API, the `[web-read]`
   block names those hosts as deliberately absent, and `scripts/webfetch.test.sh`
   asserts they are not live (today: `agent.tinyfish.ai`,
   `api.browser.tinyfish.ai`, `.tinyfish.ai`; the pattern extends to
   `api.apify.com` if Apify is ever wired).

The broker never calls a host outside `[web-read]`, and the suite extracts
every `https://` host from the broker and requires each to be an exact live
line there — so a backend cannot be half-admitted from either side.

## Consequences

- **The exfiltration surface per backend stays "one read API".** Adding
  TinyFish added two POST targets whose only function is fetch/search. It did
  not add a browser the agent can steer, even though the key on disk could
  reach one.
- **Some vendors are simply not eligible**, not "eligible with care":
  ScraperAPI (key in URL, POST passthrough), Bright Data as currently shaped
  (one host fronts everything; proxy mode passes POST), any local crawler
  library. This is a property of their API shape, not a judgment of the
  product.
- **A vendor's MCP is not a shortcut.** "Connect the MCP inside the profile"
  would bypass every layer here: MCP tool calls are HTTPS to the vendor's agent
  host (not admitted), are not Bash prefixes (the hook cannot see them), and
  onboard via a fetch-and-run form the sandbox denies by name. Using a vendor's
  act surface is a separate decision, made deliberately, with its own ADR —
  never a side effect of wanting reads to work.
- **A stored key may be over-privileged, and that is accepted.** The
  `TINYFISH_API_KEY` in a profile's `secrets.env` could drive the vendor's
  browser API; nothing in the sandbox can reach that API, so the key's excess
  scope is inert inside the boundary. The secrets template says so, so an
  operator does not mistake "I have the key" for "I can enable the feature".
- **The rule is checked offline on every `just test-offline`**, so a wildcard
  or a sibling host added "to make TinyFish work" fails before a proxy reload.
- **Cost:** a future reader that only exists behind a shared host cannot be
  used, even if its read API is excellent. That is the trade.

## Alternatives considered

- **Allow the vendor's parent domain and rely on the broker only calling the
  read endpoints.** Rejected. The broker is one caller; `curl` is denied but
  `python3` is not, and an agent can open an HTTPS connection to any admitted
  host from a script. The allowlist is the control precisely because it does
  not depend on which program is asking.
- **Scope the key instead** (vendor-side read-only tokens). Rejected as the
  primary control — not every vendor offers it (Apify documents that standby
  actors ignore scoped tokens; TinyFish issues one key for all four APIs), and
  a control that exists only when the vendor chose to build it is not a
  control this repo can rely on. Where a vendor does offer a read-only key,
  use it *as well*.
- **Admit act surfaces but gate them behind the hook's `ask` tier.** Rejected.
  The hook sees Bash prefixes; an HTTPS call from a script, or an MCP tool
  call, has no prefix to match. The only layer that reliably sees every route
  to a host is the proxy.
- **No rule — evaluate each vendor ad hoc.** Rejected on the evidence: the
  TinyFish onboarding script would have passed an ad-hoc "does it work?"
  review, and it registered an agent-driven browser in every coding agent on
  the machine. A rule with five checkable properties is what turned a
  four-vendor assessment into a table with a verdict column.
