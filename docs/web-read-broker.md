# Web-read broker (`webfetch`)

The restricted agent cannot read arbitrary web pages: `curl`/`wget` are denied
in `claude-settings.json`, the real `WebFetch` tool is not on the allow-list,
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
| `tavily` (default) | `api.tavily.com`      | **yes** (already)     | `TAVILY_API_KEY` (required) |
| `jina`      | `r.jina.ai` / `s.jina.ai`    | no — add first        | `JINA_API_KEY` (optional; keyless = rate-limited) |
| `firecrawl` | `api.firecrawl.dev`          | no — add first        | `FIRECRAWL_API_KEY` (required) |

## Usage (from inside the agent)

```bash
webfetch extract <url> [<url> ...]        # clean text/markdown of specific pages
webfetch search  "<query>" [--n 5]        # ranked, synthesized results
webfetch extract <url> --via jina         # once r.jina.ai is allowlisted
webfetch extract <url> --max 40000        # raise the per-source char cap
```

`Bash(webfetch:*)` is on the agent's allow-list, so it runs unattended with no
permission prompt (unlike the real `WebFetch` tool). Output goes to stdout and
the agent reads it like any tool result. `python3 /usr/local/bin/webfetch ...`
also works and is covered by `Bash(python3:*)` if the dedicated allow entry is
ever removed.

## Security properties

- **No new egress.** Default backend uses `api.tavily.com`, already allowlisted.
  Enabling Jina/Firecrawl requires an explicit allowlist edit (+ restart) first.
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

## Adding Jina or Firecrawl later

1. Add the host(s) to `proxy/allowed_domains.txt` (`r.jina.ai` [+ `s.jina.ai`],
   or `api.firecrawl.dev`) and `docker restart egress-proxy-<profile>`
   (allowlist edits need a restart, not just reconfigure).
2. Add the key to `secrets.env` (Jina's is optional) and recreate the agent.
3. The agent selects it with `--via jina` / `--via firecrawl`.
