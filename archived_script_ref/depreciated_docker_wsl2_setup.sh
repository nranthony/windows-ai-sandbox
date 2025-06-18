#!/usr/bin/env bash
set -euo pipefail

select rc file - zsh takes precidence
if [ -f "${HOME}/.zshrc" ]; then
  RCFILE="${HOME}/.zshrc"
else
  RCFILE="${HOME}/.bashrc"
fi

# RCFILE="${HOME}/.bashrc"

# ensure your user services keep running after the initial login
sudo loginctl enable-linger "$(id -un)"

# 1. Install Docker Engine
echo "# ----- Installing Docker Engine -----"
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release

# Add Docker's official GPG key
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg

# Add Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

echo "# ----- Configuring Rootless Docker -----"
# 2. Configure Rootless Docker
sudo apt install -y uidmap dbus-user-session

# WSL2: systemd is not always available. Ensure /etc/wsl.conf contains 'systemd=true' in the [boot] section.
sudo systemctl disable --now docker.service docker.socket

# Install rootless for the current user
dockerd-rootless-setuptool.sh install

grep -qxF 'export DOCKER_HOST=unix:///run/user/1000/docker.sock' "${RCFILE}" \
  || echo 'export DOCKER_HOST=unix:///run/user/1000/docker.sock' >> "${RCFILE}"

grep -qxF 'export PATH=$PATH:/usr/bin' "${RCFILE}" \
  || echo 'export PATH=$PATH:/usr/bin' >> "${RCFILE}"

grep -qxF 'dockerd-rootless.sh &>/dev/null &' "${RCFILE}" \
  || echo 'dockerd-rootless.sh &>/dev/null &' >> "${RCFILE}"

# grep -qxF 'sudo iptables-restore < ~/wsl-iptables.rules' "${RCFILE}" \
#   || echo 'sudo iptables-restore < ~/wsl-iptables.rules' >> "${RCFILE}"

source "${RCFILE}"

echo "# ----- Setting Up User Namespace Remapping -----"
# 3. User Namespace Remapping
# Idempotent setup for subuid/subgid
if ! grep -q "^$(whoami):100000:65536" /etc/subuid; then
  echo "$(whoami):100000:65536" | sudo tee -a /etc/subuid
fi
if ! grep -q "^$(whoami):100000:65536" /etc/subgid; then
  echo "$(whoami):100000:65536" | sudo tee -a /etc/subgid
fi

export PATH="/usr/bin:$PATH"
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"

# # WSL2: Restart rootless dockerd manually (systemctl --user might not work)
# pkill -u "$(id -u)" -f dockerd-rootless.sh || true
# # reload any unit-file changes, then start or restart your user‐level docker service
# systemctl --user daemon-reload
# systemctl --user restart docker.service

# for i in {1..10}; do
#   [ -S "$DOCKER_HOST" ] && break
#   sleep 1
# done

# --- Start Replacement Block ---

# WSL2: Manually stop and start the rootless Docker daemon, as systemctl --user is unreliable in scripts.
echo "--> Manually restarting rootless Docker daemon..."

# 1. Ensure any old instance is stopped.
pkill -u "$(id -u)" -f 'dockerd-rootless.sh' || true

# 2. Start the daemon in the background. Using `nohup` ensures it keeps running after the script exits.
#    We execute it via a new bash shell to ensure it's fully detached.
nohup /bin/bash -c "dockerd-rootless.sh" &>/dev/null &

# 3. Wait for the Docker socket to become available. This is crucial.
echo "--> Waiting for the Docker socket to become available..."
# Make sure DOCKER_HOST is set for this check, as it might not be if you haven't sourced RCFILE yet.
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
for i in {1..15}; do
    # Use `docker context` or `docker version` as a more reliable check than just the socket file.
    if docker context ls &>/dev/null; then
        echo "Docker daemon is ready."
        break
    fi
    echo "    (Attempt $i/15) Waiting for daemon..."
    sleep 1
done

# 4. Final check to ensure we can proceed.
if ! docker context ls &>/dev/null; then
    echo "Error: Rootless Docker daemon did not start correctly."
    echo "Please try opening a new terminal or running 'wsl --shutdown' and restarting."
    exit 1
fi

# --- End Replacement Block ---

echo " ----- Check Docker Version -----"
# now safe to test
docker version


echo "# ----- Secure Docker Configuration -----"
# 4. Secure Docker Configuration
mkdir -p ~/.docker

cat > ~/.docker/daemon.json << 'EOF'
{
  "userns-remap": "default",
  "no-new-privileges": true,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "default-ulimits": {
    "nofile": {
      "hard": 1024,
      "soft": 1024
    },
    "nproc": {
      "hard": 512,
      "soft": 512
    }
  },
  "storage-driver": "overlay2"
}
EOF

# (AppArmor and seccomp not supported by default in WSL2)

# 5. Resource Limits (systemd user services not available in WSL2)
# Can skip or run if systemd is enabled in your WSL2 instance

# 6. Docker Network Security
if ! docker network inspect ai-sandbox >/dev/null 2>&1; then
  docker network create \
    --driver bridge \
    --subnet=172.20.0.0/16 \
    --ip-range=172.20.240.0/20 \
    --gateway=172.20.0.1 \
    --opt com.docker.network.bridge.name=docker-secure \
    ai-sandbox
else
  echo "→ Network ai-sandbox already exists, skipping creation"
fi


# Install iptables-persistent (may have limited effect in WSL2)
sudo apt install -y iptables-persistent

# Block container-to-host except port 22 (example; adjust as needed)
# Only works if DOCKER-USER chain is present and used in your kernel (limited in WSL2)
sudo iptables -C DOCKER-USER -i docker-secure -j DROP 2>/dev/null || \
sudo iptables -I DOCKER-USER -i docker-secure -j DROP
sudo iptables -C DOCKER-USER -i docker-secure -p tcp --dport 22 -j ACCEPT 2>/dev/null || \
sudo iptables -I DOCKER-USER -i docker-secure -p tcp --dport 22 -j ACCEPT

# 7. Secure Container Template
cat > ~/run-ai-container.sh << 'EOF'
#!/bin/bash
SECURITY_OPTS="--security-opt=no-new-privileges:true"
SECURITY_OPTS="$SECURITY_OPTS --cap-drop=ALL --cap-add=CHOWN --cap-add=SETUID --cap-add=SETGID"
RESOURCE_LIMITS="--memory=4g --cpus=2.0 --pids-limit=512"
RESTRICTIONS="--network=ai-sandbox --read-only --tmpfs=/tmp:rw,noexec,nosuid,size=1g"
USER_MAP="--user=1000:1000"
docker run -it --rm $SECURITY_OPTS $RESOURCE_LIMITS $RESTRICTIONS $USER_MAP --name ai-sandbox-$(date +%s) "$@"
EOF
chmod +x ~/run-ai-container.sh

# 8. Container Health Check Script
cat > ~/check-container-security.sh << 'EOF'
#!/bin/bash
echo "=== Container Security Status ==="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo -e "\n=== Resource Usage ==="
docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.PIDs}}"
echo -e "\n=== Network Connections ==="
sudo ss -tulpn | grep docker
EOF
chmod +x ~/check-container-security.sh

# 9. Shell Aliases (idempotent)
grep -qxF 'alias docker-secure="~/run-ai-container.sh"' "${RCFILE}" \
  || echo 'alias docker-secure="~/run-ai-container.sh"' >> "${RCFILE}"

grep -qxF 'alias docker-check="~/check-container-security.sh"' "${RCFILE}" \
  || echo 'alias docker-check="~/check-container-security.sh"' >> "${RCFILE}"

# reload the file so aliases take effect
# use 'source' or '.' depending on shell compatibility
# zsh and bash both support 'source'
source "${RCFILE}"


# 10. Testing
docker run --rm hello-world
~/run-ai-container.sh ubuntu:24.04 whoami
~/run-ai-container.sh ubuntu:24.04 bash -c "cat /proc/meminfo | grep MemTotal"
~/check-container-security.sh

# 11. Security Maintenance
# Regular updates, only use trusted images, secrets management, etc.
