# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains setup scripts and configuration for a secure Windows AI development environment using WSL2 Ubuntu 24.04 LTS with rootless Docker and GPU acceleration. The setup creates an isolated "AI Sandbox" for machine learning development with CUDA support.

## Architecture

The system follows this layered architecture:
- **Windows OS** → **WSL2 Ubuntu 24.04 LTS** → **Rootless Docker** → **CUDA-enabled Dev Containers**

Key components:
- **Host Setup Scripts** (`host_setup/`): Configure WSL2 Ubuntu with rootless Docker
- **Dev Container** (`.devcontainer/`): CUDA-enabled container with uv, VS Code extensions
- **Container Testing** (`container_testing/`): PyTorch/CUDA validation notebooks and environments
- **Security Configuration**: Isolated Docker networks with iptables firewall rules

## Common Development Tasks

### Initial Setup (Run Once)
```bash
# Inside WSL Ubuntu
cd host_setup
./setup-rootless-docker-wsl.sh         # Setup rootless Docker (script uses sudo internally)
sudo ./wsl_conf_update.sh              # Configure /etc/wsl.conf
./ohmyzsh-host-setup.sh                # Optional: Install oh-my-zsh
```

### Dev Container Operations
```bash
# Start dev container
code .  # Must be run from WSL, not Windows
# Ctrl+Shift+P → "Dev Containers: Rebuild and Reopen in Container"

# Inside dev container - install ML packages into default venv
cd container_testing && uv sync
```

### Testing GPU/CUDA
```bash
# Inside dev container
jupyter notebook container_testing/cuda_test.ipynb
# Verify "CUDA available: True" in first cell
```

### Docker Operations
```bash
# All Docker commands use rootless socket
export DOCKER_HOST=unix:///run/user/1000/docker.sock

# Check Docker status
docker info  # Should show "Server: Rootless"
systemctl --user status docker.service

# Network management
docker network ls  # Should see "ai-sandbox" isolated network
```

### Debugging
```bash
# Docker service logs
journalctl --user -u docker.service -n 50

# D-Bus/systemd issues (race condition on WSL restart)
systemctl --user restart docker.service
```

## Key Files and Configuration

### Dev Container Setup
- `.devcontainer/devcontainer.json`: VS Code dev container configuration; mounts WSL2 GPU via `/dev/dxg` and `/usr/lib/wsl`
- `.devcontainer/Dockerfile`: NVIDIA CUDA 12.6.3 base image (Ubuntu 24.04), runs as root
- `.devcontainer/entrypoint.sh`: Runs oh-my-zsh and git setup on container creation (once)
- `.devcontainer/ohmyzsh-container-setup.sh`: Installs uv, oh-my-zsh, and shell plugins; creates default `~/.venv`
- `.devcontainer/set-git-global.sh`: Sets git user.name / user.email from `.env`
- `.devcontainer/ROOTLESS-DOCKER-NOTES.md`: Why root-in-container is correct with rootless Docker
- `.devcontainer/GPU-FIX-MIGRATION.md`: Notes on the `--gpus all` → `/dev/dxg` + `/usr/lib/wsl` migration (NVIDIA Container Toolkit 1.18+ / cgroup v2 fix)

### Environment Requirements
- Create `.env` file in repo root:
  ```
  GIT_NAME="your-name"
  GIT_EMAIL="your-email@example.com"
  ```
- Copy `win_setup/.wslconfig` to `C:\Users\<UserName>\.wslconfig`

### Security Configuration
- Rootless Docker daemon configuration written to `/etc/docker/daemon.json` (system-wide, read via `XDG_CONFIG_HOME`/`DOCKER_CONFIG` override)
- Systemd user unit promoted to `/etc/systemd/user/docker.service`
- Isolated Docker network: `ai-sandbox` bridge `docker-secure` (172.20.0.0/16)
- iptables `DOCKER-USER`: default DROP on `docker-secure` ingress, SSH (tcp/22) allowed
- auditd rules installed for `/etc/docker`, containerd, runc
- Container runs as **root** (UID 0 in container = host UID 1000 via rootless user-namespace mapping — see `.devcontainer/ROOTLESS-DOCKER-NOTES.md`)

## File Structure

```
├── .devcontainer/          # Dev container configuration
├── host_setup/             # WSL Ubuntu setup scripts + per-script guides
├── container_testing/      # CUDA/PyTorch test environment (uv project)
├── archived_script_ref/    # Deprecated scripts and guides (incl. rootless_docker_guide.md)
├── win_setup/              # Windows configuration (.wslconfig)
├── reports/                # Security audit reports (docker-bench)
└── images/                 # README screenshots
```

## Important Notes

- **Always run `code .` from inside WSL Ubuntu**, never from Windows
- Rootless Docker socket: `/run/user/1000/docker.sock`
- **Dev container runs as root** (container UID 0 = host UID 1000 with rootless Docker)
- **CUDA version**: 12.6.3 (requires NVIDIA driver ≥ 530.30.02, tested with 566.36)
- **GPU passthrough**: uses WSL2 device mount (`--device=/dev/dxg` + `/usr/lib/wsl` volume + `LD_LIBRARY_PATH=/usr/lib/wsl/lib`), not `--gpus all` — rootless Docker + NVIDIA Container Toolkit ≥1.18 breaks the old approach
- NVIDIA Container Toolkit pinned to `1.17.8-1` in `setup-rootless-docker-wsl.sh`
- D-Bus issues on WSL restart are handled by a kickstart block appended to `~/.zprofile` or `~/.profile`
- uv installed to `/root/.local/bin/uv`; default venv at `/root/.venv` (Python 3.12)
- Forwarded ports: 8080, 8501, 8188