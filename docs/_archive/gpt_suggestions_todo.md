# AI Sandbox Security Hardening TODO

A consolidated checklist of recommended security improvements for the **WSL AI sandbox + rootless Docker environment**.
Focus areas: **filesystem isolation, network controls, container hardening, and AI-specific risks.**

---

# 1. WSL Configuration Hardening

### Disable automatic localhost exposure

Edit `.wslconfig`:

```
[wsl2]
localhostForwarding=false
```

**Reason**

* Prevents services started in WSL or containers from automatically exposing ports to Windows.

---

### Enforce firewall routing

Ensure:

```
[wsl2]
firewall=true
```

**Reason**

* Routes WSL network traffic through Windows Defender Firewall for policy enforcement.

---

### Limit WSL resource usage

Add limits:

```
[wsl2]
memory=8GB
processors=4
swap=0
```

**Reason**

* Prevents runaway agents, fork bombs, or excessive resource usage.

---

# 2. Windows Filesystem Exposure Controls

### Disable automatic Windows drive mounts

Edit `/etc/wsl.conf`:

```
[automount]
enabled=false
```

**Reason**

* Prevents automatic exposure of `/mnt/c` and other host drives.

---

### Mount only specific directories (read-only)

Example manual mount:

```
mount -t drvfs C:\sandbox /mnt/host-sandbox -o ro
```

**Reason**

* Principle of least privilege for filesystem access.

---

# 3. Rootless Docker Improvements

### Ensure Docker runs rootless

Verify installation:

```
dockerd-rootless-setuptool.sh install
```

Verify environment variable:

```
export DOCKER_HOST=unix:///run/user/1000/docker.sock
```

**Reason**

* Prevents container → root daemon privilege escalation.

---

### Enable user namespace remapping

Edit `daemon.json`:

```
{
  "userns-remap": "default"
}
```

**Reason**

* Adds an extra UID mapping layer between container and host.

---

# 4. Docker Daemon Hardening

Edit `/etc/docker/daemon.json` and add:

```
{
  "icc": false,
  "live-restore": true
}
```

**Reason**

Disable:

```
inter-container communication
```

Prevents lateral movement between containers.

---

### Add seccomp syscall filtering

Example:

```
{
  "seccomp-profile": "/etc/docker/seccomp.json"
}
```

**Reason**

* Restricts dangerous Linux syscalls such as `ptrace`, `mount`, `kexec`.

---

# 5. Container Runtime Security

Always run containers with hardened flags:

```
docker run \
--cap-drop=ALL \
--security-opt=no-new-privileges \
--pids-limit=256 \
--memory=4g \
--read-only \
--tmpfs /tmp \
image
```

**Protections added**

* removes Linux capabilities
* blocks privilege escalation
* prevents fork bombs
* limits resource abuse
* prevents persistent malware

---

# 6. Network Isolation

### Restrict outbound container traffic

Example `iptables` policy:

```
iptables -A OUTPUT -p tcp -d github.com -j ACCEPT
iptables -A OUTPUT -p tcp -d pypi.org -j ACCEPT
iptables -A OUTPUT -p tcp -d registry.npmjs.org -j ACCEPT
iptables -A OUTPUT -j DROP
```

**Reason**

Prevents:

* data exfiltration
* malware downloads
* command-and-control connections

---

### Block inbound container connections

Example:

```
iptables -A FORWARD -i docker0 -j DROP
```

**Reason**

* Prevents external access to container services.

---

# 7. GPU Exposure Controls

Only enable GPU when required.

Default:

```
--gpus=none
```

**Reason**

* GPU drivers add kernel attack surface.

---

# 8. Health Server Security

Ensure monitoring services bind only to localhost.

Example:

```
127.0.0.1:9000
```

NOT:

```
0.0.0.0
```

**Reason**

* Prevents remote access to monitoring endpoints.

---

# 9. Logging and Auditing

Enable Docker log limits:

```
--log-driver=json-file
--log-opt max-size=10m
```

Install Linux audit logging:

```
auditd
```

Monitor:

* container exec commands
* network connections
* filesystem access

---

# 10. Secrets Management

Never store secrets directly in containers.

Use temporary mounts:

```
docker run --tmpfs /secrets
```

Load keys only when required.

Examples of sensitive items:

```
OPENAI_API_KEY
AWS credentials
SSH keys
```

**Reason**

* AI agents can leak secrets through prompt injection.

---

# 11. AI-Specific Threat Mitigations

Be aware of risks unique to AI agents:

### Prompt injection

Example attack:

```
README.md instructs agent to run malicious command
```

Mitigation strategies:

* review commands before execution
* restrict network access
* run agents in disposable containers

---

### Supply chain attacks

High-risk commands:

```
npm install
pip install
git clone
```

Mitigation:

* restrict outbound domains
* review dependencies

---

# 12. Optional Advanced Hardening

For stronger isolation consider:

### Disposable containers per task

Workflow:

```
docker run
run agent task
delete container
```

Prevents persistence.

---

### Additional sandbox layer

Architecture example:

```
Windows
↓
WSL2
↓
rootless Docker
↓
container
↓
AI agent
```

---

# Priority Implementation Order

**Critical**

1. Disable automatic Windows drive mounts
2. Restrict outbound network traffic
3. Use rootless Docker
4. Drop container capabilities
5. Enable no-new-privileges

**Important**

6. Add seccomp filtering
7. Disable localhost forwarding
8. Use read-only container filesystems
9. Limit container resources

**Nice to have**

10. Audit logging
11. Disposable containers
12. GPU isolation

---

# Expected Security Outcome

After applying these changes:

| Area                            | Security Level |
| ------------------------------- | -------------- |
| Filesystem isolation            | Strong         |
| Container privilege control     | Strong         |
| Network exfiltration resistance | Strong         |
| Agent containment               | Strong         |
| Host compromise risk            | Low            |

Overall sandbox rating:

```
~9 / 10 for local AI agent experimentation
```

---
