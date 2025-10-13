# Rootless Docker with Root Container User

## Why Root User in Container?

This dev container runs as **root** inside the container, which seems counterintuitive but is actually **correct and safe** with rootless Docker.

## How Rootless Docker Works

Rootless Docker uses **user namespace remapping**:

```
Host (WSL2)                Container
────────────────────────────────────
UID 1000 (nelly)    →     UID 0 (root)
UID 100000+         →     UID 1+ (other users)
```

### What This Means

1. **Container "root" = Your host user**
   - Container UID 0 (root) is actually host UID 1000 (you)
   - Root in container has NO special privileges on the host
   - Cannot escape container or access other users' files

2. **File Permissions Work Correctly**
   - Host files owned by UID 1000 appear as UID 0 in container
   - Container root can write to workspace (your files)
   - Non-root container users (UID 1000+) map to UID 100000+ on host (don't exist)

## Why Non-Root Container User Doesn't Work

If we tried to use a non-root user (e.g., `ubuntu` UID 1000) in the container:

```
Container UID 1000 (ubuntu) → Host UID 100000+ (nobody)
```

Result: Workspace files (owned by container UID 0 = host UID 1000) are **unwritable**.

## Security Model

### With Rootless Docker + Root Container

✅ **Host isolation**: Container root cannot affect host
✅ **File permissions**: Works correctly with bind mounts
✅ **Network isolation**: Separate Docker network
✅ **Resource limits**: Rootless Docker enforces limits

### What Container Root CANNOT Do

- ❌ Access other users' files on host
- ❌ Load kernel modules
- ❌ Modify host system
- ❌ Bind to privileged ports (<1024) on host
- ❌ Access raw network sockets

## Configuration

### devcontainer.json
```json
{
  "remoteUser": "root",
  "workspaceFolder": "/workspaces/${localWorkspaceFolderBasename}",
  "runArgs": [
    "--network=ai-sandbox",
    "--userns=host",  // Uses default rootless Docker user namespace
    "--gpus", "all"
  ]
}
```

### Dockerfile
```dockerfile
FROM nvidia/cuda:12.6.3-base-ubuntu24.04

# Install packages as root
RUN apt-get update && apt-get install -y ...

# Install miniforge in /root
ENV PATH="/root/miniforge3/bin:${PATH}"

# Run as root (safe with rootless Docker)
USER root
WORKDIR /root
```

## Common Questions

### Q: Is this secure?

**A: Yes!** Rootless Docker provides the security isolation, not the container user. Container root = unprivileged host user.

### Q: What about privilege escalation?

**A: Not possible.** Container root is already "unprivileged root" from the kernel's perspective. There's nothing to escalate to.

### Q: Should I use sudo inside the container?

**A: No need!** You're already root. Just run commands directly:
```bash
apt update  # No sudo needed
```

### Q: Can I switch to a non-root user if I want?

**A: Not recommended** with rootless Docker, as it breaks workspace permissions. If you need multi-user support, use rootful Docker instead.

## Testing Isolation

You can verify container isolation:

```bash
# Inside container (as root)
whoami           # Shows: root
id               # Shows: uid=0(root) gid=0(root)

# Try to access another user's files (will fail)
cat /home/otheruser/file  # Permission denied

# Check UID mapping
cat /proc/self/uid_map    # Shows: 0  1000  1
                          # Container UID 0 = Host UID 1000
```

## References

- [Docker Rootless Mode](https://docs.docker.com/engine/security/rootless/)
- [User Namespaces](https://man7.org/linux/man-pages/man7/user_namespaces.7.html)
- [Rootless Containers](https://rootlesscontaine.rs/)

## Summary

**With rootless Docker, running as root in the container is the correct pattern.** It provides proper file permissions while maintaining host security through user namespace isolation.
