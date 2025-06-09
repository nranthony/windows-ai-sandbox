#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 2. Configure Rootless Docker
# -----------------------------------------------------------------------------
echo "# ----- Configuring Rootless Docker -----"
sudo apt install -y uidmap dbus-user-session

# Disable any rootful Docker services
sudo systemctl disable --now docker.service docker.socket
# Remove the rootful Docker socket if it exists
if [ -e "/var/run/docker.sock" ]; then # Check if the file exists
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

# Optional: Start the rootless Docker daemon (if not already running)
# Note: You should have already done this manually or separately as instructed earlier
# if ! systemctl --user is-active docker.service &>/dev/null; then # Check if the service is active
#    systemctl --user start docker.service
# fi