# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains setup scripts and configuration for a secure Windows AI development environment using WSL2 Ubuntu 24.04 LTS with rootless Docker and GPU acceleration. The setup creates an isolated "AI Sandbox" for machine learning development with CUDA support.

## Architecture

The system follows this layered architecture:
- **Windows OS** → **WSL2 Ubuntu 24.04 LTS** → **Rootless Docker** → **CUDA-enabled Dev Containers**

Key components:
- **Host Setup Scripts** (`host_setup/`): Configure WSL2 Ubuntu with rootless Docker
- **Dev Container** (`.devcontainer/`): CUDA-enabled container with miniforge3, VS Code extensions
- **Container Testing** (`container_testing/`): PyTorch/CUDA validation notebooks and environments
- **Security Configuration**: Isolated Docker networks with iptables firewall rules

## Common Development Tasks

### Initial Setup (Run Once)
```bash
# Inside WSL Ubuntu
cd host_setup
sudo ./setup-rootless-docker-wsl.sh    # Setup rootless Docker
sudo ./wsl_conf_update.sh               # Configure WSL
./ohmyzsh-host-setup.sh                 # Optional: Install oh-my-zsh
```

### Dev Container Operations
```bash
# Start dev container
code .  # Must be run from WSL, not Windows
# Ctrl+Shift+P → "Dev Containers: Rebuild and Reopen in Container"

# Inside dev container - create ML environment
mamba env create -f ./container_testing/environment.yml
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
- `.devcontainer/devcontainer.json`: VS Code dev container configuration with CUDA support
- `.devcontainer/Dockerfile`: NVIDIA CUDA base image with miniforge3
- `.devcontainer/entrypoint.sh`: Runs oh-my-zsh and git setup on container creation

### Environment Requirements
- Create `.env` file in repo root:
  ```
  GIT_NAME="your-name"
  GIT_EMAIL="your-email@example.com"
  ```
- Copy `win_setup/.wslconfig` to `C:\Users\<UserName>\.wslconfig`

### Security Configuration
- Rootless Docker daemon configuration in `~/.config/docker/daemon.json`
- Isolated Docker network: `ai-sandbox` (172.20.0.0/16)
- iptables rules: Default DROP with SSH (tcp/22) allowed
- Container security: `--security-opt=no-new-privileges`

## File Structure

```
├── .devcontainer/          # Dev container configuration
├── host_setup/            # WSL Ubuntu setup scripts
├── container_testing/     # CUDA/PyTorch test environment
├── archived_script_ref/   # Deprecated scripts and guides
├── win_setup/            # Windows configuration files
└── reports/              # Security audit reports
```

## Important Notes

- **Always run `code .` from inside WSL Ubuntu**, never from Windows
- Rootless Docker socket: `/run/user/1000/docker.sock`
- Dev container uses root user with miniforge3 in `/root/miniforge3`
- GPU passthrough requires Windows with WSL2 and NVIDIA drivers
- D-Bus issues on WSL restart are handled by profile kickstart script