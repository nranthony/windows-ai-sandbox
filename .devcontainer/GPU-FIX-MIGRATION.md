# Dev Container GPU Fix - Migration Guide

## Problem
Rootless Docker + NVIDIA Container Toolkit 1.18+ + cgroup v2 = GPU access broken
- Error: `bpf_prog_query(BPF_CGROUP_DEVICE) failed: operation not permitted`

## Solution Applied (Option 3: WSL2 Manual GPU Mount)

### Changes to `devcontainer.json`

**BEFORE:**
```json
"containerEnv": {
  "DOCKER_HOST": "unix:///run/user/1000/docker.sock"
},
"runArgs": [
  "--network=ai-sandbox",
  "--userns=host",
  "--gpus", "all",  // ❌ BROKEN with rootless + new toolkit
  "--env-file", "${localWorkspaceFolder}/.env"
]
```

**AFTER:**
```json
"containerEnv": {
  "DOCKER_HOST": "unix:///run/user/1000/docker.sock",
  "LD_LIBRARY_PATH": "/usr/lib/wsl/lib"  // ✅ ADDED
},
"runArgs": [
  "--network=ai-sandbox",
  "--userns=host",
  "--device=/dev/dxg",  // ✅ WSL2 GPU device
  "--volume=/usr/lib/wsl:/usr/lib/wsl:ro",  // ✅ WSL2 drivers
  "--env-file", "${localWorkspaceFolder}/.env"
]
```

## Migration Steps

1. **Update `devcontainer.json`**:
   - Remove: `"--gpus", "all"`
   - Add: `"--device=/dev/dxg"`
   - Add: `"--volume=/usr/lib/wsl:/usr/lib/wsl:ro"`
   - Add to `containerEnv`: `"LD_LIBRARY_PATH": "/usr/lib/wsl/lib"`

2. **Rebuild container** - VS Code will prompt or use Command Palette: "Rebuild Container"

## Alternative Solutions (if Option 3 doesn't work)

### Option 1: Switch to Rootful Docker (most reliable)
- Remove `"--userns=host"`
- Use `"--gpus", "all"`
- Requires nvidia-container-runtime in `/etc/docker/daemon.json`

### Option 2: No GPU in Dev Container
- Remove both `"--gpus", "all"` and device mounts
- Keep `"--userns=host"` for rootless
- Run GPU workloads outside container or in separate GPU container

## Why This Happened
- NVIDIA Container Toolkit 1.18+ changed device management
- Requires BPF capabilities unavailable in rootless Docker
- WSL2 workaround mounts GPU device directly (bypasses nvidia-container-runtime)
