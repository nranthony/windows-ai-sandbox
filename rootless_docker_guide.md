# Rootless Docker Complete Setup Guide

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

---