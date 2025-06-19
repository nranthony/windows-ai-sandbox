# Rootless Docker Complete Setup Guide

This guide walks through every command and configuration in the `rootless-docker-full-setup.sh` script, explaining what it does and why it’s important. By the end, you’ll have a secure, rootless Docker daemon running inside your WSL2 Ubuntu distro.

---

## Prerequisites

- **Ubuntu 24.04 LTS** running under **WSL2** on Windows 11 (with `systemd=true` enabled in `/etc/wsl.conf`).
- A non-root user account (e.g. `dave`) with **sudo** privileges.
- Internet access to download packages and Docker binaries.
- Basic familiarity with the Linux shell, systemd (user mode), and iptables.

---

## 1. Install Docker Engine

```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release
```

- `` ensures HTTPS downloads trust the CA bundle.
- ``, ``, `` are needed to fetch and verify Docker’s GPG key and to detect your Ubuntu codename.

```bash
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
```

- Imports Docker’s official GPG key into `` for package verification.

```bash
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
```

- Adds Docker’s **stable** repository tailored to your Ubuntu release (e.g. “lunar”).

```bash
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

- Installs:
  - ``: the Docker daemon
  - ``: the Docker command-line client
  - ``: container runtime
  - ``: `docker compose` sub-command

---

## 2. Install Rootless-Docker Prerequisites

```bash
sudo apt update
sudo apt install -y uidmap dbus-user-session iptables
```

- ``: enables user-namespace mapping for rootless containers.
- `` & ``: provide a user-level D-Bus for systemd services.
- ``: used by Docker’s firewall hooks.

```bash
# Pre-seed to avoid prompts when installing iptables-persistent
echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' \
  | sudo debconf-set-selections
echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' \
  | sudo debconf-set-selections

DEBIAN_FRONTEND=noninteractive sudo apt install -y iptables-persistent
```

- Installs `` quietly, so your DOCKER-USER rules persist across reboots.

---

## 3. Disable Rootful Docker

```bash
sudo systemctl disable --now docker.service docker.socket || true
sudo rm -f /var/run/docker.sock
```

- **Stops and disables** any “rootful” Docker service to prevent conflicts.
- **Removes** the old `/var/run/docker.sock` so that only the rootless socket at `/run/user/$UID/docker.sock` will be used.

---

## 4. Install and Configure Rootless Docker

```bash
dockerd-rootless-setuptool.sh install
```

- Runs Docker’s first-party tool to bootstrap a rootless daemon under your user. This:
  - Creates `~/.config/systemd/user/docker.service` and related files.
  - Sets up `rootlesskit` networking and mounts.
  - Generates wrapper scripts (`dockerd-rootless.sh`).

```bash
sudo loginctl enable-linger "$(id -u)"
```

- **Enables “linger”** so your user’s systemd services (like Docker) keep running even after you log out.

```bash
RCFILE="$HOME/.bashrc"
SOCK="/run/user/$(id -u)/docker.sock"
grep -qxF "export DOCKER_HOST=unix://${SOCK}" "$RCFILE" \
  || echo "export DOCKER_HOST=unix://${SOCK}" >> "$RCFILE"
export DOCKER_HOST="unix://${SOCK}"
```

- Adds (if missing) and exports ``, pointing all Docker commands at your rootless socket.

---

## 5. Secure Docker Daemon Configuration

In a rootless setup—where Docker runs unprivileged under your user namespace—some default daemon settings need adjustment to ensure security, stability, and predictable resource use. Open or create `` and apply the following options:

```jsonc
{
  "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "no-new-privileges": true,
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Soft": 1024, "Hard": 1024 },
    "nproc":  { "Name": "nproc",  "Soft": 512,  "Hard": 512 }
  },
  "storage-driver": "overlay2"
}
```

- ``**:**

  - `"native.cgroupdriver=cgroupfs"` tells Docker to use the user-space cgroupfs driver rather than the `systemd` driver. Since in many WSL or non-systemd environments the kernel cgroup tree isn’t managed by systemd, using `cgroupfs` avoids failures to create and delegate cgroup controllers under `/sys/fs/cgroup`.
  - If you do enable full systemd cgroup support (e.g. Windows 11 + WSL systemd or a `genie` bottle), Docker can switch to `systemd` here for tighter integration and automatic slice management.

- ``**:**

  - Prevents any process within a container from gaining additional Linux capabilities (e.g. via setuid binaries). This restricts privilege escalation even if a container process is compromised.

- ``** & **``**:**

  - Restricts container logs to the `json-file` driver, and limits each log file to 10 MB with up to 3 rotated files. This prevents runaway log growth from filling your home directory, crucial when Docker’s root directory lives under your user account.

- ``**:**

  - Sets conservative per-container limits on open files (`nofile`) and process count (`nproc`). Without these, a runaway container could exhaust file handles or spawn too many processes, destabilizing your user session.

- ``**:**

  - `overlay2` is the recommended backend for modern kernels. It offers good performance and low overhead, and works correctly under unprivileged user namespaces.

> **Why cgroups matter**: Without a systemd-managed `/sys/fs/cgroup` hierarchy, Docker cannot enforce CPU or memory limits in rootless mode—hence the warning “Running in rootless-mode without cgroups.” By choosing `cgroupfs`, Docker will mount a delegated subtree under your home directory and manage limits itself. If you later enable systemd and proper cgroup delegation, you can switch to the `systemd` cgroup driver for full kernel-enforced resource controls.


## 6. Manage the Rootless Docker Service

```bash
SERVICE_UNIT="$HOME/.config/systemd/user/docker.service"

# Fix stray Windows paths (if any):
if grep -q "/mnt/c/" "$SERVICE_UNIT"; then
  sed -i -E \
    's#^Environment=PATH=.*#Environment=PATH='"$HOME"'/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin#' \
    "$SERVICE_UNIT"
  systemctl --user daemon-reload
fi
```

- Ensures your user-level Docker service file doesn’t reference Windows paths.

```bash
# Restart & wait-for-ready helper
restart_docker_and_wait() {
  timeout 10 systemctl --user restart docker.service
  for i in $(seq 1 30); do
    if [[ -S "$XDG_RUNTIME_DIR/docker.sock" ]] && docker info &>/dev/null; then
      echo "Rootless Docker is ready."; return 0
    fi
    sleep 1
  done
  echo "Error: Docker didn’t come up in time"; journalctl --user -u docker.service -n50
  return 1
}

if restart_docker_and_wait; then
  echo "Docker is up"; else exit 1; fi
```

- **Restarts** the service under ``, then polls:
  - **Socket presence** (`-S`)
  - `` success
- If it never becomes ready, dumps the last 50 journal lines for troubleshooting.

---

## 7. Secure Docker Networking & Firewall

### a) Create an isolated network

```bash
docker network inspect ai-sandbox &>/dev/null || \
  docker network create \
    --driver bridge \
    --subnet 172.20.0.0/16 \
    --ip-range 172.20.240.0/20 \
    --gateway 172.20.0.1 \
    --opt com.docker.network.bridge.name=docker-secure \
    ai-sandbox
```

- **Bridge driver** gives container-level isolation.
- **Custom subnet**, **IP range**, and **gateway** prevent collisions with other networks.
- `` is the Linux bridge device name.

### b) Enforce firewall rules via `DOCKER-USER`

```bash
# 1) Ensure DOCKER-USER chain exists
sudo iptables -w -t filter -L DOCKER-USER &>/dev/null || {
  sudo iptables -w -t filter -N DOCKER-USER
  sudo iptables -w -t filter -I FORWARD 1 -j DOCKER-USER
}

# 2) Drop all ingress on our bridge
sudo iptables -w -t filter -C DOCKER-USER -i docker-secure -j DROP \
  || sudo iptables -w -t filter -I DOCKER-USER -i docker-secure -j DROP

# 3) Allow SSH (tcp/22)
sudo iptables -w -t filter -C DOCKER-USER -i docker-secure -p tcp --dport 22 -j ACCEPT \
  || sudo iptables -w -t filter -I DOCKER-USER -i docker-secure -p tcp --dport 22 -j ACCEPT

# 4) Persist rules
sudo netfilter-persistent save
```

- `` chain is called before any container traffic.
- **Default DROP** ensures no unapproved external traffic.
- **Allow SSH** lets you exec into containers if needed.
- `` writes these rules to disk.

---

## 8. Verification & Troubleshooting

1. **Check Docker info:**
   ```bash
   ```

docker info

````

   - Look for **“Server: Rootless”** and no errors.

2. **Inspect service status:**

   ```bash
systemctl --user status docker.service
````

3. **View logs on errors:**
   ```bash
   ```

journalctl --user -u docker.service -n 100 --no-pager

````

4. **Verify environment variable:**

   ```bash
echo $DOCKER_HOST
````

5. **Test pull/run:**
   ```bash
   ```

docker run --rm hello-world

```

If something fails, re-read the step’s explanation above, correct any typos in paths or JSON, and ensure that WSL’s systemd cgroup support is active (for full cgroup limits).

```



<!-- Old version - keep from temp cross checks>
<!-- # Rootless Docker Complete Setup Guide

This guide details the steps in the provided `rootless-docker-full-setup.sh` script. It covers installation, configuration, security measures, and troubleshooting for setting up Docker in a rootless environment.

---

## 1. Installing Docker Engine

This step sets up Docker Engine:

- Updates the system's package repository and installs dependencies:
  - `ca-certificates`, `curl`, `gnupg`, and `lsb-release`.

- Adds Docker’s official GPG key and sets up the Docker repository for stable versions on Ubuntu.

- Installs Docker components:
  - `docker-ce`, `docker-ce-cli`, `containerd.io`, and `docker-compose-plugin`.

---

## 2. Rootless Docker Prerequisites

This step installs required packages for rootless Docker:

- `uidmap`: Manages user and group mappings.
- `dbus-user-session` and `dbus-broker`: Required for user-level session management.
- `iptables`: Essential for firewall management.

Additionally, it sets up `iptables-persistent` non-interactively for firewall rule persistence.

---

## 3. Disabling Rootful Docker

This step ensures no conflicts between rootful and rootless Docker:

- Stops and disables any existing Docker services running with root privileges.
- Removes the existing Docker socket (`/var/run/docker.sock`) if present.

---

## 4. Installing and Configuring Rootless Docker

This step uses the provided `dockerd-rootless-setuptool.sh` to:

- Install and set up the rootless Docker daemon.
- Enable user linger, allowing Docker to run without an active user session.
- Automatically configure the Docker host environment variable (`DOCKER_HOST`) in your `.bashrc`.

---

## 5. Securing Docker Daemon Configuration

Security best practices are enforced:

- Sets options in `daemon.json` for secure Docker runtime:
  - Limits logging to conserve disk space.
  - Restricts maximum file descriptors and processes.
  - Uses `no-new-privileges` for security.
  - Employs overlay2 storage for efficiency.

---

## 6. Service Management and Cleanup

This step:

- Ensures Docker’s systemd service file (`docker.service`) is correctly configured, fixing potential Windows path contamination.
- Restarts the Docker service and waits for it to be fully operational before continuing.

---

## 7. Secure Docker Networking & Firewall

To maintain a secure networking environment:

- Creates an isolated Docker network (`ai-sandbox`) with explicit subnet and gateway settings.
- Configures `iptables` to strictly control network access:
  - All incoming traffic to the Docker bridge is dropped by default.
  - Explicitly allows SSH (`tcp/22`) traffic.
- Persists firewall rules with `netfilter-persistent`.

---

## Troubleshooting & Verification

After running the script, verify Docker’s operational status:

```bash
docker info
```

If Docker doesn't start, inspect logs:

```bash
journalctl --user -u docker.service
```

Ensure the environment variable is correctly set:

```bash
echo $DOCKER_HOST
```

--- -->