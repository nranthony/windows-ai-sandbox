# Security Assessment: windows-ai-sandbox
**Date:** May 28, 2026
**Expert:** Gemini CLI (Security Specialist Mode)

## 1. Assessment of `~/.ai-sandbox`
This directory holds the persistent state and identity of the agent. It is the most sensitive data on the host.

### Critical Risks
*   **OAuth & Identity Tokens:** `gemini-home/oauth_creds.json` and `google_accounts.json` contain active session tokens. While the `Read` tool is restricted via `claude-settings.json`, any agent can use `Bash(cat ...)` to exfiltrate these.
*   **MCP Interaction Logs:** Files in `cache/claude-cli-nodejs/` store full transcripts of interactions with MCP servers (Gmail, Drive, etc.). This is a significant privacy "pot of gold."
*   **Conversation History:** `history.jsonl` contains full prompts and responses, which likely include sensitive architectural details or accidentally pasted secrets.

### Operational Risks
*   **Cache Poisoning:** The agent has write access to `cache/uv`, `cache/deno`, etc. A malicious agent could pre-seed these caches with compromised dependencies to affect future sessions.

---

## 2. Architectural Security Opinion
The system implements a very strong **Defense-in-Depth** model.

### Strengths
*   **DNS Sinkholing:** Using `dns: [127.0.0.1]` + `extra_hosts` is a highly effective way to block DNS-based data exfiltration, which is often missed in standard sandboxes.
*   **Rootless Docker userns=host:** This is the correct way to handle root-in-container. It maps container root to host UID 1000, preventing system-level host compromise.
*   **Content-Aware Hooks:** `deny-destructive.sh` correctly identifies that standard prefix-based filtering (like `permissions.deny`) cannot catch flags like `find -delete`.

### Weaknesses / Vectors
*   **Docker Socket Mount:** `docker-compose.yml` mounts `/run/user/1000/docker.sock`. This allows the agent to control the Docker daemon. Even with `Bash(docker:*)` denied, an agent can interact with the socket via raw HTTP or scripts.
*   **WebFetch (Side-Channel):** `WebFetch` executes on Anthropic's infrastructure. It bypasses the local Squid proxy entirely. Data can be exfiltrated via URL query parameters.

---

## 3. Risks in Dev Containers Context
*   **Helper-Tool Surface:** The image correctly omits `ssh`, `socat`, and `openssh-client`, effectively neutralizing most "helpful" exfiltration paths provided by VS Code extensions.
*   **Workspace Integrity:** While the sandbox protects the host, it cannot prevent an agent from injecting subtle vulnerabilities into the source code stored in `/workspace`.

---

## 4. Recommendations
1.  **Restrict Config Access:** Update the `deny-destructive.sh` hook to block *all* Bash access to `/root/.gemini` and `/root/.claude`.
2.  **Audit Docker Socket:** If the agent doesn't need to manage containers, remove the `DOCKER_HOST` socket mount.
3.  **Scoped WebFetch:** Ensure `.claude/settings.local.json` restricts `WebFetch` to specific documentation domains.
4.  **Log Rotation:** Periodically clear `mcp-logs` and history to minimize data exposure.
