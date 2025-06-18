#!/usr/bin/env bash
set -euo pipefail

if [ -f ${HOME}/.zshrc ]; then
  RCFILE="${HOME}/.zshrc"
  echo "Zsh found; using .zshrc for shell modifications."
else
  RCFILE="${HOME}/.bashrc"
  echo "Zsh not found; using .bashrc for shell modifications."
fi

# -----------------------------------------------------------------------------
# CUDA env hook for both bash and zsh (WSL 2, CUDA 12.9)
# -----------------------------------------------------------------------------

# CUDA_VER="12.9"
# CUDA_HOME="/usr/local/cuda-${CUDA_VER}"
# BASHRC="${HOME}/.bashrc"
# ZSHRC="${HOME}/.zshrc"

# TODO
# - check if zsh in place and ask if they'd like to run ohmyzsh-host-setup.sh
# Warn that script should be run again if zsh setup later
# See wsl-dbus-hack.sh -- insert into start of zshrc

# #  Ensure PATH line is present in .bashrc
# if ! grep -Fxq "export PATH=\${PATH}:${CUDA_HOME}/bin" "${BASHRC}"; then
#   echo "export PATH=\${PATH}:${CUDA_HOME}/bin" >> "${BASHRC}"
# fi

# #  Ensure WSL driver stubs are visible at run time
# if ! grep -Fxq "export LD_LIBRARY_PATH=\${LD_LIBRARY_PATH}:/usr/lib/wsl/lib" "${BASHRC}"; then
#   echo "export LD_LIBRARY_PATH=\${LD_LIBRARY_PATH}:/usr/lib/wsl/lib" >> "${BASHRC}"
# fi

# #  If zsh is present, make it inherit bash settings
# if [[ -f "${ZSHRC}" ]]; then
#   if ! grep -Fxq "source ~/.bashrc" "${ZSHRC}"; then
#     echo "source ~/.bashrc" >> "${ZSHRC}"
#   fi
# fi

# echo "✅  CUDA env lines ensured in ${BASHRC} (and ${ZSHRC} if it exists)."
# echo "   Open a new terminal or run:  source ~/.bashrc"


# -----------------------------------------------------------------------------
# Install WSL CUDA toolkit
# -----------------------------------------------------------------------------

# TODO -determine which toolkit is needed, or both
# wget https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb
# sudo dpkg -i cuda-keyring_1.1-1_all.deb
# sudo apt-get update
# sudo apt-get -y install cuda-toolkit-12-9
# sudo apt-mark hold cuda-toolkit-12-9 cuda-*
# sudo apt-mark hold nvidia-*  

# curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
#   && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
#     sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
#     sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
# sudo apt-get update
# export NVIDIA_CONTAINER_TOOLKIT_VERSION=1.17.8-1
#   sudo apt-get install -y \
#       nvidia-container-toolkit=${NVIDIA_CONTAINER_TOOLKIT_VERSION} \
#       nvidia-container-toolkit-base=${NVIDIA_CONTAINER_TOOLKIT_VERSION} \
#       libnvidia-container-tools=${NVIDIA_CONTAINER_TOOLKIT_VERSION} \
#       libnvidia-container1=${NVIDIA_CONTAINER_TOOLKIT_VERSION}

# -----------------------------------------------------------------------------
# Install Docker Engine
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
# Configure Rootless Docker prerequisites  
# -----------------------------------------------------------------------------
echo "# ----- Installing prerequisites for Rootless Docker -----"
sudo apt update
sudo apt install -y uidmap dbus-user-session iptables

# Pre-seed answers so iptables-persistent install is non-interactive
echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' \
  | sudo debconf-set-selections
echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' \
  | sudo debconf-set-selections

# Install iptables-persistent without prompts
DEBIAN_FRONTEND=noninteractive sudo apt install -y iptables-persistent

# -----------------------------------------------------------------------------  
# Disable any rootful Docker and remove socket  
# -----------------------------------------------------------------------------
echo "# ----- Disabling rootful Docker services -----"
sudo systemctl disable --now docker.service docker.socket || true

if [ -e "/var/run/docker.sock" ]; then
    echo "removing old docker.sock file"
    sudo rm -f "/var/run/docker.sock"
fi

# -----------------------------------------------------------------------------  
# Install and configure Rootless Docker  
# -----------------------------------------------------------------------------
echo "# ----- Installing Rootless Docker toolchain -----"
dockerd-rootless-setuptool.sh install

echo "# ----- Enabling linger for rootless Docker -----"
sudo loginctl enable-linger "$(id -u)"

echo "# ----- Configuring DOCKER_HOST environment -----"
# RCFILE="${HOME}/.bashrc"
SOCK="/run/user/$(id -u)/docker.sock"
grep -qxF "export DOCKER_HOST=unix://${SOCK}" "$RCFILE" \
  || echo "export DOCKER_HOST=unix://${SOCK}" >> "$RCFILE"
export DOCKER_HOST="unix://${SOCK}"

# -----------------------------------------------------------------------------  
# Secure Docker Daemon Configuration  
# -----------------------------------------------------------------------------
echo "# ----- Securing Docker Daemon (user-level) -----"
DOCKER_DAEMON_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/docker"
mkdir -p "$DOCKER_DAEMON_DIR"

cat > "$DOCKER_DAEMON_DIR/daemon.json" << 'EOF'
{
  "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "no-new-privileges": true,
  "log-driver": "json-file",
  "log-opts": { "max-size":"10m", "max-file":"3" },
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 1024,
      "Soft": 1024
    },
    "nproc": {
      "Name": "nproc",
      "Hard": 512,
      "Soft": 512
    }
  },
  "storage-driver": "overlay2"
}
EOF

# -----------------------------------------------------------------------------  
# Modify and Start Rootless Docker Service  
# -----------------------------------------------------------------------------
echo "# ----- Starting Rootless Docker service -----"
SERVICE_UNIT="$HOME/.config/systemd/user/docker.service"

if [ ! -f "$SERVICE_UNIT" ]; then
    echo "Error: Docker service file not found at $SERVICE_UNIT"
    exit 1
fi

# Fix stray Windows paths if present
if grep -q "/mnt/c/" "$SERVICE_UNIT"; then
    echo "Found Windows paths in service file—fixing..."
    sed -i -E \
      's#^Environment=PATH=.*#Environment=PATH='"$HOME"'/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin#' \
      "$SERVICE_UNIT"
    systemctl --user daemon-reload
fi

# Function to restart and wait for readiness
restart_docker_and_wait() {
    echo "Restarting rootless Docker…"
    timeout 10 systemctl --user restart docker.service || {
        echo "systemctl restart failed"; return 1; }

    for i in $(seq 1 30); do
        if [[ -S "$XDG_RUNTIME_DIR/docker.sock" ]] && docker info &>/dev/null; then
            echo "→ Rootless Docker is ready."
            return 0
        fi
        echo "  (Attempt $i/30) Waiting…"
        sleep 1
    done

    echo "Error: Docker daemon not ready after 30 s."
    journalctl --user -u docker.service -n 50 --no-pager
    return 1
}

if restart_docker_and_wait; then
    echo "Docker is up."
else
    echo "Docker failed to start."
    exit 1
fi

# -----------------------------------------------------------------------------  
# Configure Secure Docker Network & Firewall  
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

echo "# ----- Applying DOCKER-USER iptables rules -----"
# Ensure DOCKER-USER exists in filter table
if ! sudo iptables -w -t filter -L DOCKER-USER >/dev/null 2>&1; then
  echo "→ Creating DOCKER-USER chain"
  sudo iptables -w -t filter -N DOCKER-USER
  # Hook it so all forwarded packets hit DOCKER-USER first
  sudo iptables -w -t filter -I FORWARD 1 -j DOCKER-USER
fi

# Drop all ingress on docker-secure bridge
sudo iptables -w -t filter -C DOCKER-USER -i docker-secure -j DROP 2>/dev/null \
  || sudo iptables -w -t filter -I DOCKER-USER -i docker-secure -j DROP

# Allow SSH (tcp/22) on that bridge
sudo iptables -w -t filter -C DOCKER-USER -i docker-secure -p tcp --dport 22 -j ACCEPT 2>/dev/null \
  || sudo iptables -w -t filter -I DOCKER-USER -i docker-secure -p tcp --dport 22 -j ACCEPT

# Persist rules
echo "# ----- Saving firewall rules -----"
sudo netfilter-persistent save


echo "# ----- Setup complete! -----"
