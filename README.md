# windows-ai-sandbox

Setup notes and scripts for my WSL2 Ubuntu 'sandbox'. Work in progress. See [Rootless Docker Guide](./rootless_docker_guide.md) for a comprehensive setup.

## General Information

This repository contains scripts and notes for configuring a secure, rootless Docker environment specifically on WSL2 running Ubuntu on Windows.

## Miscellaneous Notes

### Modified Service File

Ensure the Docker service environment paths in `/home/[username]/.config/systemd/user/docker.service` are wrapped in quotes:

```ini
[Service]
Environment=PATH="/usr ... "
```

**Note:** The path issue is now handled by the setup script. If any problems persist, refer to the uninstall section below.

## Uninstalling Rootless Docker

To reset your environment, execute:

```bash
/usr/bin/dockerd-rootless-setuptool.sh uninstall -f; /usr/bin/rootlesskit rm -rf /home/"$(id -un)"/.local/share/docker
/usr/bin/rootlesskit rm -rf /home/"$(id -un)"/.local/share/docker
```

## Docker security and testing

### Docker Bench
```bash
git clone https://github.com/docker/docker-bench-security.git
cd docker-bench-security
# run docker bench in user to access user specific docker socket - sudo testing is not the idea here
docker-bench-security.sh
```
see `docker-bench-security-report.md`



