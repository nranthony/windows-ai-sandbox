#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 2. Configure Rootless Docker
# -----------------------------------------------------------------------------
echo "# ----- Configuring Rootless Docker -----"
sudo apt install -y uidmap dbus-user-session dbus-broker iptables iptables-persistent

# Disable any rootful Docker services
sudo systemctl disable --now docker.service docker.socket
# Remove the rootful Docker socket if it exists
if [ -e "/var/run/docker.sock" ]; then # Check if the file exists
    echo "removing docker.sock file"
    sudo rm "/var/run/docker.sock"
fi

# Install the rootless toolchain
dockerd-rootless-setuptool.sh install

# allow lingering docker service
sudo loginctl enable-linger "$(id -u)"

# write recommended path to .bashrc
RCFILE="${HOME}/.bashrc"
SOCK="/run/user/$(id -u)/docker.sock"
grep -qxF "export DOCKER_HOST=unix://${SOCK}" "$RCFILE" \
  || echo "export DOCKER_HOST=unix://${SOCK}" >> "$RCFILE"

export DOCKER_HOST="unix://${SOCK}"

# ───────────────────────────────────────────────────────────────────────────────
# Modify the rootless docker service configuration before starting
SERVICE_UNIT="$HOME/.config/systemd/user/docker.service"

# Verify service file exists before modification
if [ ! -f "$SERVICE_UNIT" ]; then
    echo "Error: Docker service file not found at $SERVICE_UNIT"
    echo "The rootless Docker installation may have failed."
    exit 1
fi
# Check if service file has problematic Windows paths
if grep -q "/mnt/c/" "$SERVICE_UNIT"; then
    echo "Found Windows paths in service file - fixing..."
    # Edit the Environment=PATH line to exclude Win OS paths
    sed -i -E \
    's#^Environment=PATH=.*#Environment=PATH='"$HOME"'/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin#' \
    "$SERVICE_UNIT"
    # reload daemon service after docker.service changes
    systemctl --user daemon-reload
fi

restart_docker_and_wait() {
    echo "Restarting rootless Docker …"
    timeout 10 systemctl --user restart docker.service || {
        echo "systemctl restart failed"; return 1; }

    # Probe readiness (max 30 s)
    for i in $(seq 1 30); do
        [[ -S "$XDG_RUNTIME_DIR/docker.sock" ]] && docker info &>/dev/null && {
            echo "→ Rootless Docker is ready."; return 0; }
        echo "  (Attempt $i/30) Waiting …"
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

echo "# ----- Docker Version -----"
docker version
