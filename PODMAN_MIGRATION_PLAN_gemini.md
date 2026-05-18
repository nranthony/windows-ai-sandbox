# PODMAN MIGRATION PLAN: SECURE NON-ROOT AI SANDBOX

**Target:** Transition from Rootless Docker (Container UID 0 → Host UID 1000) to Rootless Podman (Container UID 1000 → Host UID 1000) with NVIDIA GPU support and egress hardening.

---

## 1. ARCHITECTURAL SHIFT
| Component | Current (Docker Rootless) | Target (Podman Rootless) |
|---|---|---|
| **Identity** | `userns=host`; Container Root = Host 1000 | `userns=keep-id`; Container 1000 = Host 1000 |
| **Daemon** | `dockerd` (User Session) | Daemonless (Direct OCI) |
| **Networking** | Bridge + Proxy (internal:true) | Pasta/Slirp4netns + Proxy (Podman Network) |
| **GPU** | `/dev/dxg` + NVIDIA Toolkit | NVIDIA CDI (Container Device Interface) |
| **Orchestration** | Docker Compose | Podman Compose (or `podman-compose` python) |

---

## 2. PHASE 1: HOST PREPARATION (WSL2 UBUNTU 24.04)
### 2.1 Install Podman 5.x
Podman 5.0+ is required for the `pasta` network driver (faster/more stable for rootless).
```bash
sudo apt update && sudo apt install -y podman podman-compose
```
### 2.2 Configure SubUIDs
Ensure the host user has sufficient subuid/subgid range for remapping beyond UID 1000.
```bash
# Verify /etc/subuid contains:
# <username>:100000:65536
```
### 2.3 NVIDIA CDI Generation
Podman uses CDI for GPU passthrough. Generate the CDI spec on the host:
```bash
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
# Ensure non-root can read it (usually /var/run/cdi or ~/.config/cdi)
```

---

## 3. PHASE 2: IMAGE REFACTORING (`Dockerfile`)
The image must transition from "Root-perceived" to "User-perceived".

### 3.1 Define the Non-Root User
```dockerfile
# Add non-root user matching host UID 1000
RUN groupadd -g 1000 agent && \
    useradd -u 1000 -g agent -m -s /usr/bin/zsh agent

# Adjust permissions for baked-in tools
RUN chown -R agent:agent /root/.venv && \
    mv /root/.venv /home/agent/.venv && \
    chown agent:agent /usr/local/bin/uv*

USER agent
WORKDIR /workspace
```

### 3.2 Permission Normalization
Since we are using `keep-id`, paths like `/workspace` will be owned by `agent:agent` automatically if the host folder is owned by UID 1000.

---

## 4. PHASE 3: RUNTIME ORCHESTRATION (`podman-compose.yml`)
### 4.1 Identity Mapping
The core of the request. Use `userns: keep-id`.
```yaml
services:
  ai-sandbox:
    user: "1000:1000"
    userns_mode: "keep-id:uid=1000,gid=1000" # Map host 1000 to container 1000
    security_opt:
      - no-new-privileges
      - seccomp=./seccomp.json
    cap_drop:
      - ALL
    devices:
      - "nvidia.com/gpu=all" # CDI notation
```

### 4.2 Network Isolation
Podman networks handle `internal` similarly to Docker.
```yaml
networks:
  sandbox-internal:
    internal: true
  sandbox-external:
    driver: bridge
```

---

## 5. PHASE 4: VS CODE INTEGRATION
Update `.devcontainer/devcontainer.json` to tell VS Code to use Podman instead of Docker.
```json
{
  "name": "Podman AI Sandbox",
  "dockerComposeFile": "../podman-compose.yml",
  "service": "ai-sandbox",
  "workspaceFolder": "/workspace",
  "remoteUser": "agent",
  "containerUser": "agent",
  "customizations": {
    "vscode": {
      "settings": {
        "dev.containers.dockerPath": "podman"
      }
    }
  }
}
```

---

## 6. PHASE 5: SECURITY VERIFICATION
### 6.1 UID Verification
Inside the container, run:
```bash
id # Should return uid=1000(agent)
touch /workspace/test.txt && ls -l /workspace/test.txt # Should be owned by agent
```
### 6.2 Egress Tripwire
Verify Squid is still the only exit:
```bash
curl --connect-timeout 2 https://google.com # FAIL
HTTPS_PROXY=http://egress-proxy:3128 curl https://api.anthropic.com # PASS
```

---

## 7. KEY RISKS & MITIGATIONS
*   **CDI Complexity:** CDI is newer than `nvidia-container-toolkit`'s Docker integration. If CDI fails, fallback to manual `/dev/dxg` device mapping as used in the current Docker setup.
*   **Pasta MTU:** On some WSL2 setups, Podman's `pasta` driver might need MTU adjustment (`--net=pasta:mtu=1500`).
*   **Socket Forwarding:** Podman's user socket is at `/run/user/1000/podman/podman.sock`. Ensure environment variables are updated.
