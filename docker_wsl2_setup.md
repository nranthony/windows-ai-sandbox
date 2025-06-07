#!/bin/bash
set -euo pipefail

# 1. Install Docker Engine
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

# 2. Configure Rootless Docker
sudo apt install -y uidmap dbus-user-session

# Ensure system Docker is stopped and disabled
sudo systemctl disable --now docker.service docker.socket

# Install rootless Docker for current user
dockerd-rootless-setuptool.sh install

# Enable and start rootless Docker as a systemd user service
systemctl --user enable docker
systemctl --user start docker

# Set DOCKER_HOST for current user (idempotent)
grep -qxF 'export DOCKER_HOST=unix:///run/user/1000/docker.sock' ~/.bashrc || \
  echo 'export DOCKER_HOST=unix:///run/user/1000/docker.sock' >> ~/.bashrc

# Apply environment immediately for this session
export DOCKER_HOST=unix:///run/user/1000/docker.sock

# 3. User Namespace Remapping
# Idempotent setup for subuid/subgid
if ! grep -q "^$(whoami):100000:65536" /etc/subuid; then
  echo "$(whoami):100000:65536" | sudo tee -a /etc/subuid
fi
if ! grep -q "^$(whoami):100000:65536" /etc/subgid; then
  echo "$(whoami):100000:65536" | sudo tee -a /etc/subgid
fi

# Restart rootless Docker to apply userns changes
systemctl --user restart docker

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

# Note: AppArmor and seccomp custom profiles are not supported by default in WSL2.

# 5. Resource Limits (systemd user services are available with systemd enabled)
# To set further resource controls, use systemctl --user edit docker and add [Service] limits.

# 6. Docker Network Security
docker network create \
  --driver bridge \
  --subnet=172.20.0.0/16 \
  --ip-range=172.20.240.0/20 \
  --gateway=172.20.0.1 \
  --opt com.docker.network.bridge.name=docker-secure \
  ai-sandbox || true

# Install iptables-persistent (effectiveness limited in WSL2)
sudo apt install -y iptables-persistent

# Block container-to-host except port 22 (adjust as needed)
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
sudo netstat -tulpn | grep docker
EOF
chmod +x ~/check-container-security.sh

# 9. Bash Aliases (idempotent)
grep -qxF 'alias docker-secure="~/run-ai-container.sh"' ~/.bashrc || \
  echo 'alias docker-secure="~/run-ai-container.sh"' >> ~/.bashrc
grep -qxF 'alias docker-check="~/check-container-security.sh"' ~/.bashrc || \
  echo 'alias docker-check="~/check-container-security.sh"' >> ~/.bashrc

# 10. Testing (manual; you can comment/uncomment as needed)
docker run --rm hello-world
~/run-ai-container.sh ubuntu:24.04 whoami
~/run-ai-container.sh ubuntu:24.04 bash -c "cat /proc/meminfo | grep MemTotal"
~/check-container-security.sh

# 11. Security Maintenance
# Regularly run: sudo apt update && sudo apt upgrade -y
# Only use trusted images.
# Always use read-only volume mounts when possible.
# Never store secrets in images or containers; use --env-file or Docker secrets.
# Monitor with sudo ausearch -k docker | tail -20

# END OF SCRIPT
