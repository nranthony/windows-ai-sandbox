# Rootless Docker for WSL — **Hardened One‑Shot Setup Guide**
*(matches `setup-rootless-docker-wsl.sh`, 18 June 2025)*

This semi-abridged guide walks through the installation script, explaining *what* each command does *and* *why* it matters. Follow it and you’ll end up with:

* a **rootless Docker daemon** that survives log‑outs and WSL reboots,  
* a single, system‑wide configuration in **`/etc/docker`**,  
* an automatically repaired **systemd user session** at every shell login, and  
* an isolated **`ai‑sandbox`** network protected by firewall rules.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| **WSL 2** running **Ubuntu 24.04 LTS** | `/etc/wsl.conf` must contain `systemd=true`. |
| **Non‑root user** (e.g. `dave`) with `sudo` | Script adds a *narrow* password‑less sudo rule for session restarts. |
| Internet access | Needed to fetch Docker packages and GPG keys. |
| Basic shell & systemd knowledge | Helpful for troubleshooting. |

---
## 1  Install Docker Engine & Minimal Prereqs
```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg uidmap dbus-user-session
```
* **`ca-certificates` / `curl` / `gnupg`** – fetch & verify Docker’s repo.  
* **`uidmap`** – enables user‑namespace ID mapping (rootless).  
* **`dbus-user-session`** – per‑login D‑Bus, required for systemd `--user`.

### Add the official Docker repo
```bash
sudo install -m0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg |
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg]       https://download.docker.com/linux/ubuntu       $(. /etc/os-release && echo $VERSION_CODENAME) stable" |
  sudo tee /etc/apt/sources.list.d/docker.list
```
Key is stored read‑only; repo line auto‑detects your codename.

### Install engine components
```bash
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

---

## 2  Remove Rootful Docker
```bash
sudo systemctl disable --now docker.service docker.socket || true
```
Stops & disables the privileged daemon so only the rootless socket is used.

---

## 3  Prepare Persistent User Services

### 3a  Password‑less restart for broken sessions
```bash
sudo tee /etc/sudoers.d/99-wsl-user-restart <<EOF
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart user@*.service
EOF
sudo chmod 0440 /etc/sudoers.d/99-wsl-user-restart
```
Allows **only** `systemctl restart user@UID.service` without a password.

### 3b  Enable *linger*
```bash
sudo loginctl enable-linger "$USER"
```
Keeps user services (Docker) running even when no terminal is open.

---

## 4  Bootstrap Rootless Docker
```bash
dockerd-rootless-setuptool.sh install
```
Creates `~/.config/systemd/user/docker.service`, wrapper scripts & rootlesskit network.

---

## 5  Harden & Promote the Service Unit
```bash
TEMP=~/.config/systemd/user/docker.service
PERM=/etc/systemd/user/docker.service
sed -i -E 's#^Environment=PATH=.*#Environment=PATH='"$HOME"'/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin#' "$TEMP"
sudo mkdir -p /etc/systemd/user
sudo mv "$TEMP" "$PERM"
sudo chmod 644 "$PERM"
```
* Moves the unit to a distro‑portable location.  
* Scrubs Windows paths and pins a safe Linux‑only `PATH`.

---

## 6  Single Source of Truth: `/etc/docker`

### 6a  System‑wide **`daemon.json`**
```bash
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json <<'EOF'
{
  "no-new-privileges": true,
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Soft": 1024, "Hard": 1024 },
    "nproc":  { "Name": "nproc",  "Soft": 512,  "Hard": 512 }
  },
  "storage-driver": "overlay2"
}
EOF
```
Note: explicit `"native.cgroupdriver=cgroupfs"` is no longer required on Ubuntu 24.04.

### 6b  Service drop‑in to force the daemon to read `/etc/docker`
```ini
[Service]
Environment=XDG_CONFIG_HOME=/etc/docker
Environment=DOCKER_CONFIG=/etc/docker
Environment=DOCKER_CLI_CONFIG=/etc/docker/config.json
```

---

## 7  Login Kick‑start Script
Appended to `~/.profile` or `~/.zprofile`:
```bash
# BEGIN DOCKER WSL KICKSTART
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
if ! [ -S "${DBUS_SESSION_BUS_ADDRESS#*=}" ]; then
  sudo systemctl restart "user@$(id -u).service"
fi
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
# END DOCKER WSL KICKSTART
```
Repairs D‑Bus if it’s missing and exports `DOCKER_HOST` for every shell.

---

## 8  Start & Verify Docker
```bash
systemctl --user daemon-reload
systemctl --user enable docker.service
systemctl --user restart docker.service
docker info | grep Rootless
```

---

## 9  Install `iptables` & Persistent Rules
```bash
sudo apt install -y iptables
DEBIAN_FRONTEND=noninteractive sudo apt install -y iptables-persistent
```

---

## 10  Create an Isolated Network
```bash
docker network create   --driver bridge   --subnet 172.20.0.0/16   --ip-range 172.20.240.0/20   --gateway 172.20.0.1   --opt com.docker.network.bridge.name=docker-secure   ai-sandbox
```

---

## 11  Harden Ingress with `DOCKER-USER`
```bash
sudo iptables -N DOCKER-USER 2>/dev/null || true
sudo iptables -I FORWARD 1 -j DOCKER-USER 2>/dev/null || true
sudo iptables -I DOCKER-USER -i docker-secure -j DROP
sudo iptables -I DOCKER-USER -i docker-secure -p tcp --dport 22 -j ACCEPT
sudo netfilter-persistent save
```

---

## 12  Reboot the Distro
```powershell
wsl --shutdown
```
Open a new terminal and confirm:
```bash
docker info | grep Server
```
Should show **`Server: Docker … (rootless)`**.

---

### What’s New vs. the Old Guide?

| Area | Old | **New** |
|------|-----|---------|
| Config location | `$HOME/.config/docker` | **`/etc/docker`** + drop‑in |
| Service unit | in `$HOME` | **`/etc/systemd/user`** |
| Session repair | manual | **Auto kick‑start** |
| Password‑less sudo | none | restart `user@UID.service` only |
| cgroup driver | forced `cgroupfs` | default (Ubuntu 24.04 handles it) |
| iptables timing | pre‑Docker | post‑Docker |

---

