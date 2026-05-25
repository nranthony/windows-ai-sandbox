# Numerai Setup Guide

## API Credentials

Two credential types exist, with different env vars:

| Type | Env var(s) | Format | Created at |
|---|---|---|---|
| Custom API key (numerapi) | `NUMERAI_PUBLIC_ID` + `NUMERAI_SECRET_KEY` | two separate values | numer.ai → Account → Custom API Keys |
| MCP key | `NUMERAI_MCP_AUTH` | `Token PUBLIC_KEY$PRIVATE_KEY` (single combined) | numer.ai → Account → Automation → Create MCP Key |

### Minimum scopes for tournament participation

Auto-selected when creating an MCP key:

1. Upload submissions and pickled models
2. Download previous submissions and pickled models
3. View historical submission info
4. View user info (balance, withdrawal history)

The `stake` scope also exists — skip it unless you want the agent managing NMR stakes.

### Key creation flow

1. Log in to `https://numer.ai`
2. Go to Account tab
3. **Custom API key:** select "Custom API Keys", name the key, select scopes, confirm with password. The secret is shown once in a banner notification.
4. **MCP key:** under "Automation" section, click "Create MCP Key" (auto-selects the four scopes above).

## MCP Server

The Numerai MCP is a **hosted remote server** — not an npm or Python package. No local install needed.

- SSE transport: `https://api-tournament.numer.ai/mcp/sse`
- HTTP transport: `https://api-tournament.numer.ai/mcp`

### Claude Code setup

```bash
claude mcp add --transport http numerai https://api-tournament.numer.ai/mcp \
  --header "Authorization: Token ${NUMERAI_MCP_AUTH}"
```

### Codex CLI setup

```bash
curl -sL http://numer.ai/install-mcp.sh | bash
```

Writes to `~/.codex/config.toml`:

```toml
[mcp_servers.numerai]
url = "https://api-tournament.numer.ai/mcp/sse"

[mcp_servers.numerai.env_http_headers]
Authorization = "NUMERAI_MCP_AUTH"
```

### Cursor setup (`~/.cursor/mcp.json`)

```json
{
  "numerai": {
    "url": "https://api-tournament.numer.ai/mcp/sse",
    "headers": {
      "Authorization": "Token ${env:NUMERAI_MCP_AUTH}"
    }
  }
}
```

### Available tools (~13)

| Tool | Purpose |
|---|---|
| `check_api_credentials` | Verify authentication |
| `create_model` | Create a new tournament model |
| `upload_model` | Upload a pickle file for automated submissions |
| `get_model_profile` | Retrieve model details |
| `get_model_performance` | Performance metrics |
| `get_leaderboard` | Tournament leaderboard data |
| `get_tournaments` | List available tournaments |
| `get_current_round` | Current round info |
| `list_datasets` | Available datasets for download |
| `run_diagnostics` | Run model diagnostics |
| `graphql_query` | Raw GraphQL (uses introspection for custom queries) |

### Companion Skills

Numerai publishes Skills (in `numerai/example-scripts` on GitHub) that pair with the MCP tools:

- **numerai-experiment-design** — design, run, and report experiments
- **numerai-model-implementation** — add new ML architectures
- **numerai-model-upload** — create and deploy pickle files

## Proxy Allowlist Domains

All Numerai traffic routes through a single GraphQL endpoint plus S3 presigned URLs for data transfer. Staking is also handled server-side via GraphQL (no direct Ethereum RPC calls from the client).

### Required domains

```
# Core API (GraphQL + MCP — all tournament operations)
api-tournament.numer.ai

# Website (MCP device-token auth flow, key creation)
numer.ai

# S3 data buckets (presigned URLs for dataset download + submission upload)
# Bucket names are returned dynamically by the GraphQL API; these are the
# known ones. If a download/upload 403s, check Squid access.log for the
# actual S3 subdomain and add it here.
numerai-datasets-us-west-2.s3.amazonaws.com
numerai-datasets-us-west-2.s3.us-west-2.amazonaws.com
numerai-datasets.s3.amazonaws.com
numerai-public-datasets.s3-us-west-2.amazonaws.com
```

### Draft allowlist block

For `proxy/allowed_domains.txt` — goes in PROJECT-PERSISTENT tier, commented by default:

```
# --- Numerai tournament API + MCP [numerai] ---
# GraphQL API (all tournament ops: data listing, submissions, staking, MCP)
# api-tournament.numer.ai
# Website (MCP device-token auth flow, key creation)
# numer.ai
# S3 data buckets (presigned URLs for dataset download + submission upload).
# Bucket names are returned dynamically by the GraphQL API; these are the
# known ones. If a download/upload 403s, check Squid access.log for the
# actual S3 subdomain and add it here.
# numerai-datasets-us-west-2.s3.amazonaws.com
# numerai-datasets-us-west-2.s3.us-west-2.amazonaws.com
# numerai-datasets.s3.amazonaws.com
# numerai-public-datasets.s3-us-west-2.amazonaws.com
```

### Verifying after first use

Check for blocked requests after a real download/upload cycle:

```bash
docker exec egress-proxy-<profile> cat /var/log/squid/access.log | grep TCP_DENIED
```

Any `TCP_DENIED` lines with S3 subdomains not in the list above should be added to the `[numerai]` block.

## Environment Variables Summary

```bash
# numerapi (Python library)
export NUMERAI_PUBLIC_ID="your-public-id"
export NUMERAI_SECRET_KEY="your-secret-key"

# MCP server
export NUMERAI_MCP_AUTH="Token PUBLIC_KEY$PRIVATE_KEY"
```

These are different schemes: numerapi uses two separate vars; the MCP uses one combined var with the `Token ` prefix.

## Numerai Signals

Signals (tournament_id=11) and CryptoSignals (tournament_id=12) use the same `api-tournament.numer.ai` endpoint as Classic (tournament_id=8). No additional domains needed.
