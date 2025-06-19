#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

echo "--- Starting Rootless Docker Setup for WSL ---"
sudo apt-get update

# -----------------------------------------------------------------------------  
# --- Install Prerequisites ---
# -----------------------------------------------------------------------------  
echo "--- Installing Docker Engine and prerequisites..."
sudo apt-get install -y ca-certificates curl gnupg uidmap dbus-user-session

# Add Docker's official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Set up the repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Disable the rootful Docker daemon
sudo systemctl disable --now docker.service docker.socket || true


# -----------------------------------------------------------------------------  
# --- Configure System for Persistence and Automation ---
# -----------------------------------------------------------------------------  

echo "--- Configuring system for automated startup..."

# 2a: Safely configure passwordless sudo for the user session restart command
echo "--- Granting current user (${USER}) passwordless sudo for session restart..."
SUDOERS_FILE="/etc/sudoers.d/99-wsl-user-restart"
SUDOERS_RULE="${USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart user@*.service"
echo "${SUDOERS_RULE}" | sudo tee "${SUDOERS_FILE}" > /dev/null
sudo chmod 0440 "${SUDOERS_FILE}"

# -----------------------------------------------------------------------------  
# Enable lingering for the current user to allow services to start at boot
sudo loginctl enable-linger "${USER}"


# # -----------------------------------------------------------------------------  
# # Secure Docker Daemon Configuration  
# # -----------------------------------------------------------------------------
# echo "# ----- Securing Docker Daemon (user-level) -----"
# DOCKER_DAEMON_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/docker"
# mkdir -p "$DOCKER_DAEMON_DIR"

# cat > "$DOCKER_DAEMON_DIR/daemon.json" << 'EOF'
# {
#   "exec-opts": ["native.cgroupdriver=cgroupfs"],
#   "no-new-privileges": true,
#   "log-driver": "json-file",
#   "log-opts": { "max-size":"10m", "max-file":"3" },
#   "default-ulimits": {
#     "nofile": {
#       "Name": "nofile",
#       "Hard": 1024,
#       "Soft": 1024
#     },
#     "nproc": {
#       "Name": "nproc",
#       "Hard": 512,
#       "Soft": 512
#     }
#   },
#   "storage-driver": "overlay2"
# }
# EOF

# -----------------------------------------------------------------------------  
# --- Install Docker as Rootless and Move Service File to a Permanent Location ---
# -----------------------------------------------------------------------------  

echo "--- Installing rootless toolchain and creating permanent service file..."

# Run the setup tool. It will create the service file in the temporary user location.
dockerd-rootless-setuptool.sh install

# # This is the temporary location of the generated service file
# TEMP_SERVICE_FILE="${HOME}/.config/systemd/user/docker.service"
# # This is the permanent, system-wide location
# PERMANENT_SERVICE_FILE="/etc/systemd/user/docker.service"

# if [ ! -f "$TEMP_SERVICE_FILE" ]; then
#     echo "Error: Docker service file not found after setup. Aborting."
#     exit 1
# fi

# # Fix potential Windows PATH issues in the generated service file
# echo "--- Hardening the service file..."
# sed -i -E \
#   's#^Environment=PATH=.*#Environment=PATH='"$HOME"'/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin#' \
#   "$TEMP_SERVICE_FILE"

# # Move the perfected service file to the permanent system location
# echo "--- Moving service file to ${PERMANENT_SERVICE_FILE}..."
# sudo mv "$TEMP_SERVICE_FILE" "$PERMANENT_SERVICE_FILE"
# sudo chmod 644 "$PERMANENT_SERVICE_FILE" # Set standard permissions




# -----------------------------------------------------------------------------  
# Secure Docker Daemon Configuration (system-wide)  
# -----------------------------------------------------------------------------
echo "# ----- Writing hardened daemon.json to /etc/docker/ -----"
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json > /dev/null << 'EOF'
{
  "no-new-privileges": true,
  "log-driver": "json-file",
  "log-opts": { "max-size":"10m", "max-file":"3" },
  "default-ulimits": {
    "nofile": { "Name":"nofile","Hard":1024,"Soft":1024 },
    "nproc":  { "Name":"nproc", "Hard":512, "Soft":512 }
  },
  "storage-driver": "overlay2"
}
EOF
sudo chmod 644 /etc/docker/daemon.json


# -----------------------------------------------------------------------------  
# Promote rootless service file to /etc/systemd/user/  
# -----------------------------------------------------------------------------
echo "# ----- Moving rootless service into /etc/systemd/user -----"
TEMP_SERVICE_FILE="${HOME}/.config/systemd/user/docker.service"
PERM_SERVICE_FILE="/etc/systemd/user/docker.service"

if [ ! -f "$TEMP_SERVICE_FILE" ]; then
  echo "Error: expected $TEMP_SERVICE_FILE not found. Aborting." >&2
  exit 1
fi

# harden its PATH line so it always includes your ~/.local/bin
sed -i -E \
  "s#^Environment=PATH=.*#Environment=PATH=${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin#" \
  "$TEMP_SERVICE_FILE"

sudo mkdir -p /etc/systemd/user
sudo mv "$TEMP_SERVICE_FILE" "$PERM_SERVICE_FILE"
sudo chmod 644 "$PERM_SERVICE_FILE"


# -----------------------------------------------------------------------------  
# Inject config‐location env‐vars into the service unit  
# -----------------------------------------------------------------------------
echo "# ----- Adding DOCKER_CONFIG & XDG_CONFIG_HOME overrides -----"

# Create a systemd-user drop-in for docker.service
DROPIN_DIR="$(systemctl --user show --property=FragmentPath docker.service | cut -d= -f2).d"
# e.g. /etc/systemd/user/docker.service.d or ~/.config/systemd/user/docker.service.d
sudo mkdir -p "$DROPIN_DIR"

sudo tee "$DROPIN_DIR/override.conf" > /dev/null << 'EOF'
[Service]
# point both daemon and CLI at /etc/docker
Environment=XDG_CONFIG_HOME=/etc/docker
Environment=DOCKER_CONFIG=/etc/docker
Environment=DOCKER_CLI_CONFIG=/etc/docker/config.json
EOF


# -----------------------------------------------------------------------------  
# --- Install the Login Kickstart Script ---
# -----------------------------------------------------------------------------  
echo "--- Installing the login kickstart script..."

# Using a heredoc for the script content is cleaner.
# The `|| true` at the end prevents `set -e` from exiting the script prematurely.
read -r -d '' KICKSTART_SCRIPT <<'EOF' || true
# BEGIN DOCKER WSL KICKSTART
# This block was added by the setup-rootless-docker-wsl.sh script.
# It fixes a race condition between systemd and WSLg at boot.
if [ -n "$WSL_DISTRO_NAME" ] && [ -e /run/systemd/system ]; then
  # Set the standard D-Bus address for the systemd-managed user session
  export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
  
  # If the socket doesn't exist, the session is broken. Restart it.
  if ! [ -S "${DBUS_SESSION_BUS_ADDRESS#*=}" ]; then
    echo "Systemd user session is broken. Restarting it..." >&2
    sudo /usr/bin/systemctl restart "user@$(id -u).service"
  fi
fi
# Always ensure DOCKER_HOST is set for this terminal session
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
# END DOCKER WSL KICKSTART
EOF

# The target file depends on the user's default shell
if [[ "$SHELL" == *"zsh"* ]]; then
  PROFILE_FILE="${HOME}/.zprofile"
else
  PROFILE_FILE="${HOME}/.profile"
fi
echo "--- Installing kickstart to ${PROFILE_FILE}..."

# If the kickstart block doesn't already exist, append it.
# The 'touch' command ensures the file exists before we grep it.
touch "${PROFILE_FILE}"
if ! grep -q "# BEGIN DOCKER WSL KICKSTART" "${PROFILE_FILE}"; then
  echo -e "\n${KICKSTART_SCRIPT}\n" >> "${PROFILE_FILE}"
  echo "Kickstart script installed successfully."
else
  echo "Kickstart script already exists. Skipping."
fi


# -----------------------------------------------------------------------------  
# --- Restart Docker in the now-healthy session ---
# -----------------------------------------------------------------------------  

echo "--- Starting Docker in the current session for immediate use..."
# The kickstart will handle this on next login, but we do it once here manually.

echo "# ----- Reloading systemd-user and enabling Docker -----"
systemctl --user daemon-reload
systemctl --user enable docker.service
systemctl --user restart docker.service

echo "Waiting for Docker to be ready..."
sleep 5 # Give it a few seconds to start up
if docker ps &>/dev/null; then
  echo "✅  Rootless Docker is now configured and running:"
  echo "   • daemon.json → /etc/docker/daemon.json"
  echo "   • service unit → /etc/systemd/user/docker.service"
  echo "   • override drop-in → ${DROPIN_DIR}/override.conf"
else
  echo "❌ Docker failed to start. Check 'systemctl --user status docker.service'."
  exit 1
fi

# -----------------------------------------------------------------------------  
# --- Configure Secure Docker Network & Firewall  
# -----------------------------------------------------------------------------
echo "--- Setting up ip tables..."
sudo apt install -y iptables

# Pre-seed answers so iptables-persistent install is non-interactive
echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' \
  | sudo debconf-set-selections
echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' \
  | sudo debconf-set-selections

# Install iptables-persistent without prompts
DEBIAN_FRONTEND=noninteractive sudo apt install -y iptables-persistent

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

echo ""
echo "--- Setup Complete! ---"
echo "Please run 'wsl --shutdown' from PowerShell and start a new terminal for the changes to take full effect."