# Web-read broker (`webfetch`)

The restricted agent cannot read arbitrary web pages: `curl`/`wget` are denied
in `claude-settings.json`, the real `WebFetch` tool is not on the template's
allow-list (repos scope it per domain with `WebFetch(domain:<host>)` in their
own `.claude/settings.local.json` — see `docs/permissions-model.md`),
and Squid only permits the handful of hosts in `proxy/allowed_domains.txt`.
That is deliberate — every domain added to the allowlist is also a place the
agent could POST to (an exfil channel), so we do **not** widen it to the dozens
of research / news / PDF / UGC domains an open-ended verification pass needs.

Instead the agent reads the web **through a hosted reader API that is already
allowlisted**. The remote service performs the arbitrary-URL egress from *its*
infrastructure and returns clean text; the sandbox's own egress surface never
grows. `webfetch` is the thin broker in front of that service.

## What it is

A single stdlib-only Python script baked into the image at
`/usr/local/bin/webfetch` (source: `sandbox_templates/bin/webfetch`). No pip
deps — `urllib` honors `HTTPS_PROXY`, so every request is forced through the
Squid sidecar like all other egress.

Backends (pluggable):

| `--via`     | Host                         | Allowlisted?          | Key |
|-------------|------------------------------|-----------------------|-----|
| `tavily`    | `api.tavily.com`             | **yes** (already)     | `TAVILY_API_KEY` (required) |
| `jina`      | `r.jina.ai` / `s.jina.ai`    | **yes** (since 08-26) | `JINA_API_KEY` (optional; keyless = rate-limited) |
| `firecrawl` | `api.firecrawl.dev`          | **yes** (since 08-08) | `FIRECRAWL_API_KEY` (required) |
| `tinyfish`  | `api.search.tinyfish.ai` + `api.fetch.tinyfish.ai` | **yes** (since 08-25) | `TINYFISH_API_KEY` (required) |

TinyFish is wired for its **Search and Fetch APIs only** (both free tier, no
wallet) — the rule is
[ADR-0012](adr/0012-web-read-backends-get-read-hosts-only.md). The same key also unlocks the vendor's Agent and Browser APIs and an
MCP server (`agent.tinyfish.ai`) — a cloud browser the model steers, i.e. a
write surface (logins, form-fills, arbitrary POSTs). Those hosts are not
allowlisted, the broker never calls them, and `scripts/webfetch.test.sh` locks
both facts. Do not "connect" the TinyFish MCP inside a profile to get them; the
vendor's `npx -y @tiny-fish/cli connect --all` onboarding is a fetch-and-run
form the sandbox denies by name, and it also puts the key on argv.

Note the host is `api.firecrawl.**dev**` — `api.firecrawl.com` is not what the
broker calls, and allowlisting it yields a TCP_DENIED that reads like a bad key.

## Usage (from inside the agent)

```bash
webfetch backends                                 # which backends are usable in this profile
webfetch extract <url> [<url> ...] --via <b>      # clean text/markdown of specific pages
webfetch search  "<query>" --via <b> [--n 5]      # ranked results
webfetch extract <url> --via <b> --max 40000      # raise the per-source char cap
```

`--via` is required and there is no default
([ADR-0011](adr/0011-web-read-backends-are-peers-with-no-default.md)). The
backends are peers: the agent lists them, picks one that is ready, and on any
failure exit code moves to another. A baked-in default would make one vendor's
quota wall or outage read as "the web is unreachable" — Tavily's HTTP 432 did
exactly that in a live profile before this change.

`Bash(webfetch:*)` is on the agent's allow-list, so it runs unattended with no
permission prompt (unlike the real `WebFetch` tool). Output goes to stdout and
the agent reads it like any tool result. `python3 /usr/local/bin/webfetch ...`
also works and is covered by `Bash(python3:*)` if the dedicated allow entry is
ever removed.

## Security properties

- **No new egress.** The backends resolve to six allowlisted hosts in the
  `[web-read]` block (`api.tavily.com`, `api.firecrawl.dev`,
  `api.search.tinyfish.ai`, `api.fetch.tinyfish.ai`, `r.jina.ai`,
  `s.jina.ai`) — arbitrary-URL fetching happens on
  *their* infrastructure, so the sandbox's own surface does not grow with the
  pages read. Each backend is, however, one more host the agent can POST to;
  enabling Jina requires an explicit allowlist edit (+ reload) first.
- **Keys never on argv.** Read from the environment only, so they stay out of
  the Bash-tool transcript, shell history, and Squid's URL log.
- **Bounded output.** Per-source character cap (`--max`, default 20 000) so a
  hostile page can't flood agent context.
- **Untrusted-content banner.** Each block is prefixed with a marker that the
  text is web data, not instructions. This does **not** neutralize prompt
  injection — fetched content is still adversarial input; the banner only marks
  the trust boundary. Treat everything `webfetch` returns as untrusted.

## Key management

Keys live in the per-profile `secrets.env`, injected as an optional
(`required: false`) `env_file` on the agent service — the same mechanism as
`db.env`, `chmod 600` by `profile.sh`, outside the repo tree under
`~/.ai-sandbox/profiles/<profile>/`.

```bash
cp sandbox_templates/common/secrets.env.template \
   ~/.ai-sandbox/profiles/<profile>/secrets.env
$EDITOR ~/.ai-sandbox/profiles/<profile>/secrets.env    # set TAVILY_API_KEY=tvly-...
# env_file is read at container CREATE — recreate the agent to pick it up:
scripts/profile.sh <profile> up
```

`scripts/profile.sh <profile> up` also drops a `secrets.env.example` copy of the
template into the profile dir.

## Enabling Firecrawl

`api.firecrawl.dev` is allowlisted (block `[web-read]`), so only the key is
left:

1. Set `FIRECRAWL_API_KEY=fc-...` in `~/.ai-sandbox/profiles/<p>/secrets.env`.
2. `scripts/profile.sh <p> recreate` — `env_file` is read at container CREATE,
   and a plain `up` will not re-read it for an already-running agent.
3. `webfetch extract <url> --via firecrawl`.

## Enabling TinyFish

Both API hosts are allowlisted (block `[web-read]`), so only the key is left:

1. Set `TINYFISH_API_KEY=sk-tinyfish-...` in `~/.ai-sandbox/profiles/<p>/secrets.env`.
2. `scripts/profile.sh <p> recreate` (env_file is read at container CREATE).
3. `webfetch search "<query>" --via tinyfish` / `webfetch extract <url> --via tinyfish`.

Fetch takes up to 10 URLs per request; the broker batches longer lists.
Search returns snippets, not a synthesized answer — `extract` the hits you want.

## Testing

`bash scripts/webfetch.test.sh` — offline, no key. It runs the broker as a
real subprocess with `urllib.request.urlopen` shimmed, so it measures (not
infers) that no request leaves when a key is missing, that keys travel in
headers and never in URLs (Squid logs URLs), that every host the broker calls
is an exact live allowlist line and the write-surface hosts are not, that every
env var it reads is named in `secrets.env.template`, and that the untrusted
banner is the first thing on stdout with hostile text passing through verbatim
after it. Part of `just test-offline`.

## Enabling Jina

Both hosts are allowlisted (block `[web-read]`, live since 2026-08-26) and
keyless use works, so `--via jina` runs with no setup. To lift the keyless
rate limit, set `JINA_API_KEY=jina_...` in `secrets.env` and recreate the
agent.

## Gating a backend again

Comment its hosts in `[web-read]` and reload the proxy — then move the hosts
into a case arm in `scripts/webfetch.test.sh` expecting `0` (the suite
requires every host the broker names to be live), and re-word the skill
table, this file's table, and `secrets.env.template`, all of which say
"allowlisted". Jina was gated exactly this way until 2026-08-26.
