# windows-ai-sandbox

Setup notes and scripts for my WSL2 Ubuntu 'sandbox'. Work in progress. See [Rootless Docker Guide](./rootless_docker_guide.md) for a comprehensive setup.

# General Information

This repository contains scripts and notes for configuring a secure, rootless Docker environment specifically on WSL2 running Ubuntu on Windows.

# Usage

* Inside WSL Ubuntu
* Clone this repo and `cd` into it
* Run `./rootless-docker-full-setup.sh`
* Run `code .` and ensure Remote Development extension pack is installed
* Add a .env file in repo workspace root and add git name and email.
``` bash
GIT_NAME="dave"
GIT_EMAIL="1234567+dave@users.noreply.github.com"
```
* Ctrl/CMD + Shift + P and select: `Dev Containers: Rebuild and Reopen in Container`
* Rootless docker should start as a dev container; see `devcontainer.json` for parameters.
    * `entrypoint.sh` will setup git global variables, and run a full ohmyzsh setup script.




# Miscellaneous Notes

### Issue - dbus persistence
* currently debugging why bus is not available after restarts...
`systemctl restart usr@1000.service` resolves the issue - not sure if .bashrc should have this call or not

### Modified Service File

~~Ensure the Docker service environment paths in `/home/[username]/.config/systemd/user/docker.service` are wrapped in quotes:~~

```ini
[Service]
Environment=PATH="/usr ... "
```

**UPDATED** The path issue is now handled by the setup script. If any problems persist, refer to the uninstall section below.

## Uninstalling Rootless Docker

To reset your environment, execute:

```bash
/usr/bin/dockerd-rootless-setuptool.sh uninstall -f; /usr/bin/rootlesskit rm -rf /home/"$(id -un)"/.local/share/docker
/usr/bin/rootlesskit rm -rf /home/"$(id -un)"/.local/share/docker
```

## Docker security and testing

### Docker Bench

Given that the docker bench is run rootless, there are a number of moot points - anybody feedback from those with time/interest in finding ways to harden this is truly appreciated.
```bash
git clone https://github.com/docker/docker-bench-security.git
cd docker-bench-security
# run docker bench in user to access user specific docker socket - sudo testing is not the idea here
docker-bench-security.sh
```
see `docker-bench-security-report.md`
