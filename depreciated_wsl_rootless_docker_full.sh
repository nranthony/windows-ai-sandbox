#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 0. Detect which RC file to update (zsh preferred, otherwise bash)
# -----------------------------------------------------------------------------
if [ -f "${HOME}/.zshrc" ]; then
  RCFILE="${HOME}/.zshrc"
else
  RCFILE="${HOME}/.bashrc"
fi

# -----------------------------------------------------------------------------
# 1. Install Docker Engine
# -----------------------------------------------------------------------------
echo "# ----- Installing Docker Engine -----"
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release

sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) \
  signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# -----------------------------------------------------------------------------
# 2. Configure Rootless Docker
# -----------------------------------------------------------------------------
echo "# ----- Configuring Rootless Docker -----"
sudo apt install -y uidmap dbus-user-session

# Disable any rootful Docker services
sudo systemctl disable --now docker.service docker.socket 2>/dev/null || true

# Install the rootless toolchain
dockerd-rootless-setuptool.sh install

# Prepare exports in your RC file
SOCK="/run/user/$(id -u)/docker.sock"

grep -qxF "export DOCKER_HOST=unix://${SOCK}" "$RCFILE" \
  || echo "export DOCKER_HOST=unix://${SOCK}" >> "$RCFILE"

# grep -qxF 'export PATH=$PATH:/usr/bin' "$RCFILE" \
#   || echo 'export PATH=$PATH:/usr/bin' >> "$RCFILE"

# Ensure the daemon will auto-start on login
grep -qxF "nohup bash -lc 'dockerd-rootless.sh >/dev/null 2>&1 &' &" "$RCFILE" \
  || echo "nohup bash -lc 'dockerd-rootless.sh >/dev/null 2>&1 &' &" >> "$RCFILE"

# -----------------------------------------------------------------------------
# 3. Start Rootless Docker and wait for readiness
# -----------------------------------------------------------------------------
echo "# ----- Starting Rootless Docker Daemon -----"
pkill -u "$(id -u)" -f dockerd-rootless.sh 2>/dev/null || true
if ! pgrep -u "$(id -u)" -f dockerd-rootless.sh >/dev/null; then
  nohup bash -lc 'dockerd-rootless.sh >/dev/null 2>&1 &' &
fi

echo "# ----- Waiting for Docker to respond -----"
for i in {1..15}; do
  if docker info &>/dev/null; then
    echo "→ Rootless Docker is ready."
    break
  fi
  echo "    (Attempt $i/15) Waiting…"
  sleep 1
done

if ! docker info &>/dev/null; then
  echo "Error: Rootless Docker daemon did not start."
  exit 1
fi

echo "# ----- Docker Version -----"
docker version

# -----------------------------------------------------------------------------
# 4. Secure Docker Daemon Configuration
# -----------------------------------------------------------------------------
echo "# ----- Securing Docker Daemon -----"
# Determine the daemon config directory
DOCKER_DAEMON_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/docker"
# Create it if it doesn’t exist
mkdir -p "$DOCKER_DAEMON_DIR"
# Write your daemon.json there
cat > "$DOCKER_DAEMON_DIR/daemon.json" << 'EOF'
{
  "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "no-new-privileges": true,
  "log-driver": "json-file",
  "log-opts": { "max-size":"10m", "max-file":"3" },
  "default-ulimits": {
    "nofile": { "hard":1024, "soft":1024 }, 
    "nproc":  { "hard":512,  "soft":512  }
  },
  "storage-driver": "overlay2"
}
EOF

# -----------------------------------------------------------------------------
# 5. Docker Network Security
# -----------------------------------------------------------------------------
echo "# ----- Configuring Secure Docker Network -----"
if ! docker network inspect ai-sandbox >/dev/null 2>&1; then
  docker network create \
    --driver bridge \
    --subnet 172.20.0.0/16 \
    --ip-range 172.20.240.0/20 \
    --gateway 172.20.0.1 \
    --opt com.docker.network.bridge.name=docker-secure \
    ai-sandbox
else
  echo "→ ai-sandbox network exists, skipping"
fi

sudo apt install -y iptables-persistent
sudo iptables -C DOCKER-USER -i docker-secure -j DROP 2>/dev/null \
  || sudo iptables -I DOCKER-USER -i docker-secure -j DROP
sudo iptables -C DOCKER-USER -i docker-secure -p tcp --dport 22 -j ACCEPT 2>/dev/null \
  || sudo iptables -I DOCKER-USER -i docker-secure -p tcp --dport 22 -j ACCEPT

# -----------------------------------------------------------------------------
# 6. Secure Container Launch Template
# -----------------------------------------------------------------------------
echo "# ----- Creating Secure Container Launcher -----"
cat > "${HOME}/run-ai-container.sh" << 'EOF'
#!/usr/bin/env bash
SEC_OPTS="--security-opt=no-new-privileges:true \
--cap-drop=ALL --cap-add=CHOWN --cap-add=SETUID --cap-add=SETGID"
RES_LIM="--memory=4g --cpus=2.0 --pids-limit=512"
RESTR="--network=ai-sandbox --read-only \
--tmpfs=/tmp:rw,noexec,nosuid,size=1g"
USER_MAP="--user=$(id -u):$(id -g)"
docker run -it --rm $SEC_OPTS $RES_LIM $RESTR $USER_MAP \
  --name ai-sandbox-$(date +%s) "$@"
EOF
chmod +x "${HOME}/run-ai-container.sh"

# -------------------
