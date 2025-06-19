# --------------------------------------------------------------------------------------------
# Docker Bench for Security v1.6.0
#
# Docker, Inc. (c) 2015-2025
#
# Checks for dozens of common best-practices around deploying Docker containers in production.
# Based on the CIS Docker Benchmark 1.6.0.
# --------------------------------------------------------------------------------------------

[WARN] Some tests might require root to run

Initializing 2025-06-10T18:32:17-04:00


Section A - Check results

[INFO] 1 - Host Configuration
[INFO] 1.1 - Linux Hosts Specific Configuration
WARNING: Running in rootless-mode without cgroups. Systemd is required to enable cgroups in rootless-mode.
[WARN] 1.1.1 - Ensure a separate partition for containers has been created (Automated)
[INFO] 1.1.2 - Ensure only trusted users are allowed to control Docker daemon (Automated)
[INFO]       * Users: 
[WARN] 1.1.3 - Ensure auditing is configured for the Docker daemon (Automated)
[WARN] 1.1.4 - Ensure auditing is configured for Docker files and directories -/run/containerd (Automated)
[WARN] 1.1.5 - Ensure auditing is configured for Docker files and directories - /var/lib/docker (Automated)
[WARN] 1.1.6 - Ensure auditing is configured for Docker files and directories - /etc/docker (Automated)
[WARN] 1.1.7 - Ensure auditing is configured for Docker files and directories - docker.service (Automated)
[INFO] 1.1.8 - Ensure auditing is configured for Docker files and directories - containerd.sock (Automated)
[INFO]        * File not found
[WARN] 1.1.9 - Ensure auditing is configured for Docker files and directories - docker.socket (Automated)
[WARN] 1.1.10 - Ensure auditing is configured for Docker files and directories - /etc/default/docker (Automated)
[INFO] 1.1.11 - Ensure auditing is configured for Dockerfiles and directories - /etc/docker/daemon.json (Automated)
[INFO]        * File not found
[WARN] 1.1.12 - 1.1.12 Ensure auditing is configured for Dockerfiles and directories - /etc/containerd/config.toml (Automated)
[INFO] 1.1.13 - Ensure auditing is configured for Docker files and directories - /etc/sysconfig/docker (Automated)
[INFO]        * File not found
[WARN] 1.1.14 - Ensure auditing is configured for Docker files and directories - /usr/bin/containerd (Automated)
[WARN] 1.1.15 - Ensure auditing is configured for Docker files and directories - /usr/bin/containerd-shim (Automated)
[WARN] 1.1.16 - Ensure auditing is configured for Docker files and directories - /usr/bin/containerd-shim-runc-v1 (Automated)
[WARN] 1.1.17 - Ensure auditing is configured for Docker files and directories - /usr/bin/containerd-shim-runc-v2 (Automated)
[WARN] 1.1.18 - Ensure auditing is configured for Docker files and directories - /usr/bin/runc (Automated)
[INFO] 1.2 - General Configuration
[NOTE] 1.2.1 - Ensure the container host has been Hardened (Manual)
[PASS] 1.2.2 - Ensure that the version of Docker is up to date (Manual)
[INFO]        * Using 28.2.2 which is current
[INFO]        * Check with your operating system vendor for support and security maintenance for Docker

[INFO] 2 - Docker daemon configuration
[NOTE] 2.1 - Run the Docker daemon as a non-root user, if possible (Manual)
[WARN] 2.2 - Ensure network traffic is restricted between containers on the default bridge (Scored)
[PASS] 2.3 - Ensure the logging level is set to 'info' (Scored)
[PASS] 2.4 - Ensure Docker is allowed to make changes to iptables (Scored)
[PASS] 2.5 - Ensure insecure registries are not used (Scored)
[PASS] 2.6 - Ensure aufs storage driver is not used (Scored)
[INFO] 2.7 - Ensure TLS authentication for Docker daemon is configured (Scored)
[INFO]      * Docker daemon not listening on TCP
[INFO] 2.8 - Ensure the default ulimit is configured appropriately (Manual)
[INFO]      * Default ulimit doesn't appear to be set
[WARN] 2.9 - Enable user namespace support (Scored)
[PASS] 2.10 - Ensure the default cgroup usage has been confirmed (Scored)
[PASS] 2.11 - Ensure base device size is not changed until needed (Scored)
[WARN] 2.12 - Ensure that authorization for Docker client commands is enabled (Scored)
[WARN] 2.13 - Ensure centralized and remote logging is configured (Scored)
[WARN] 2.14 - Ensure containers are restricted from acquiring new privileges (Scored)
[WARN] 2.15 - Ensure live restore is enabled (Scored)
[WARN] 2.16 - Ensure Userland Proxy is Disabled (Scored)
[INFO] 2.17 - Ensure that a daemon-wide custom seccomp profile is applied if appropriate (Manual)
[INFO] Ensure that experimental features are not implemented in production (Scored) (Deprecated)

[INFO] 3 - Docker daemon configuration files
[PASS] 3.1 - Ensure that the docker.service file ownership is set to root:root (Automated)
[PASS] 3.2 - Ensure that docker.service file permissions are appropriately set (Automated)
[PASS] 3.3 - Ensure that docker.socket file ownership is set to root:root (Automated)
[PASS] 3.4 - Ensure that docker.socket file permissions are set to 644 or more restrictive (Automated)
[PASS] 3.5 - Ensure that the /etc/docker directory ownership is set to root:root (Automated)
[PASS] 3.6 - Ensure that /etc/docker directory permissions are set to 755 or more restrictively (Automated)
[INFO] 3.7 - Ensure that registry certificate file ownership is set to root:root (Automated)
[INFO]      * Directory not found
[INFO] 3.8 - Ensure that registry certificate file permissions are set to 444 or more restrictively (Automated)
[INFO]      * Directory not found
[INFO] 3.9 - Ensure that TLS CA certificate file ownership is set to root:root (Automated)
[INFO]      * No TLS CA certificate found
[INFO] 3.10 - Ensure that TLS CA certificate file permissions are set to 444 or more restrictively (Automated)
[INFO]       * No TLS CA certificate found
[INFO] 3.11 - Ensure that Docker server certificate file ownership is set to root:root (Automated)
[INFO]       * No TLS Server certificate found
[INFO] 3.12 - Ensure that the Docker server certificate file permissions are set to 444 or more restrictively (Automated)
[INFO]       * No TLS Server certificate found
[INFO] 3.13 - Ensure that the Docker server certificate key file ownership is set to root:root (Automated)
[INFO]       * No TLS Key found
[INFO] 3.14 - Ensure that the Docker server certificate key file permissions are set to 400 (Automated)
[INFO]       * No TLS Key found
[INFO] 3.15 - Ensure that the Docker socket file ownership is set to root:docker (Automated)
[INFO]       * File not found
[INFO] 3.16 - Ensure that the Docker socket file permissions are set to 660 or more restrictively (Automated)
[INFO]       * File not found
[INFO] 3.17 - Ensure that the daemon.json file ownership is set to root:root (Automated)
[INFO]       * File not found
[INFO] 3.18 - Ensure that daemon.json file permissions are set to 644 or more restrictive (Automated)
[INFO]       * File not found
[PASS] 3.19 - Ensure that the /etc/default/docker file ownership is set to root:root (Automated)
[PASS] 3.20 - Ensure that the /etc/default/docker file permissions are set to 644 or more restrictively (Automated)
[INFO] 3.21 - Ensure that the /etc/sysconfig/docker file permissions are set to 644 or more restrictively (Automated)
[INFO]       * File not found
[INFO] 3.22 - Ensure that the /etc/sysconfig/docker file ownership is set to root:root (Automated)
[INFO]       * File not found
[PASS] 3.23 - Ensure that the Containerd socket file ownership is set to root:root (Automated)
[PASS] 3.24 - Ensure that the Containerd socket file permissions are set to 660 or more restrictively (Automated)

[INFO] 4 - Container Images and Build File
[INFO] 4.1 - Ensure that a user for the container has been created (Automated)
[INFO]      * No containers running
[NOTE] 4.2 - Ensure that containers use only trusted base images (Manual)
[NOTE] 4.3 - Ensure that unnecessary packages are not installed in the container (Manual)
[NOTE] 4.4 - Ensure images are scanned and rebuilt to include security patches (Manual)
[WARN] 4.5 - Ensure Content trust for Docker is Enabled (Automated)
[WARN] 4.6 - Ensure that HEALTHCHECK instructions have been added to container images (Automated)
[WARN]      * No Healthcheck found: [ubuntu:latest]
[WARN]      * No Healthcheck found: [hello-world:latest]
[PASS] 4.7 - Ensure update instructions are not used alone in the Dockerfile (Manual)
[NOTE] 4.8 - Ensure setuid and setgid permissions are removed (Manual)
[INFO] 4.9 - Ensure that COPY is used instead of ADD in Dockerfiles (Manual)
[INFO]      * ADD in image history: [ubuntu:latest]
[NOTE] 4.10 - Ensure secrets are not stored in Dockerfiles (Manual)
[NOTE] 4.11 - Ensure only verified packages are installed (Manual)
[NOTE] 4.12 - Ensure all signed artifacts are validated (Manual)

[INFO] 5 - Container Runtime
[INFO]   * No containers running, skipping Section 5
[PASS] 5.1 - Ensure swarm mode is not Enabled, if not needed (Automated)

[INFO] 6 - Docker Security Operations
[INFO] 6.1 - Ensure that image sprawl is avoided (Manual)
[INFO]      * There are currently: 2 images
[INFO] 6.2 - Ensure that container sprawl is avoided (Manual)
[INFO]      * There are currently a total of 1 containers, with 0 of them currently running

[INFO] 7 - Docker Swarm Configuration
[PASS] 7.1 - Ensure that the minimum number of manager nodes have been created in a swarm (Automated) (Swarm mode not enabled)
[PASS] 7.2 - Ensure that swarm services are bound to a specific host interface (Automated) (Swarm mode not enabled)
[PASS] 7.3 - Ensure that all Docker swarm overlay networks are encrypted (Automated)
[PASS] 7.4 - Ensure that Docker's secret management commands are used for managing secrets in a swarm cluster (Manual) (Swarm mode not enabled)
[PASS] 7.5 - Ensure that swarm manager is run in auto-lock mode (Automated) (Swarm mode not enabled)
[PASS] 7.6 - Ensure that the swarm manager auto-lock key is rotated periodically (Manual) (Swarm mode not enabled)
[PASS] 7.7 - Ensure that node certificates are rotated as appropriate (Manual) (Swarm mode not enabled)
[PASS] 7.8 - Ensure that CA certificates are rotated as appropriate (Manual) (Swarm mode not enabled)
[PASS] 7.9 - Ensure that management plane traffic is separated from data plane traffic (Manual) (Swarm mode not enabled)


Section C - Score

[INFO] Checks: 86
[INFO] Score: -2


#
ChatGPT summary of results in context of rootless docker inside WSL:

rootless Docker reduces your attack surface by design. The goal isn't perfection in the CIS benchmark, but real-world practical hardening within rootless constraints.

Let’s break your results down and focus on what matters most — especially for rootless, dev sandbox setups.

🔐 Top Security Priorities for Your Setup
Here are the areas worth focusing on:

✅ 1. Rootless Mode is Enabled — Big Win
✔️ You're already not running as root — a huge step in container security.

✔️ DOCKER_HOST=unix:///run/user/1000/docker.sock ensures only your user can access the daemon.

⚠️ 2. Missing Auditing Configuration (Section 1.1.x)
Many lines like:

[WARN] Ensure auditing is configured for Docker files and directories

These are low-priority for personal/dev setups, but important if you're:

Operating in a production, multi-user system.

Required to log access to binaries/configs like /usr/bin/runc, /etc/docker, /var/lib/docker.

✅ What you can do: Ignore in sandbox.
🔐 What you’d do in prod: Enable auditd, and add these files to audit rules.

⚠️ 3. Cgroups Not Enabled (Important in Rootless Context)
WARNING: Running in rootless-mode without cgroups. Systemd is required to enable cgroups in rootless-mode.

This limits your ability to:

Control memory/CPU limits inside containers

Set ulimits or resource constraints

✅ What you can do:
Make sure you're using dbus-user-session and systemd --user. You might need to ensure cgroup2 is mounted in WSL.

📌 I can help walk through a cgroups check if you'd like.

✅ 4. Docker Daemon Not Listening on TCP
[INFO] Docker daemon not listening on TCP

Great — this removes a huge remote attack vector. No need for TLS or remote auth.

⚠️ 5. User Namespace Support Not Enabled
[WARN] 2.9 - Enable user namespace support (Scored)

You're already running rootless, so this is less important. In rootful mode, user namespaces are crucial to prevent UID 0 inside a container from mapping to UID 0 on the host. In rootless, that's irrelevant — you're not root anywhere.

✅ Safe to ignore in your case.

⚠️ 6. Missing no-new-privileges + Seccomp AppArmor (2.14–2.17)
[WARN] 2.14 - Ensure containers are restricted from acquiring new privileges

You do have "no-new-privileges": true in your daemon.json:

json
Copy
Edit
"no-new-privileges": true
But the scanner likely missed it because it expects it in /etc/docker/daemon.json, not user-level rootless config.

✅ You’re already good here, but the scanner doesn’t recognize rootless context.

⚠️ 7. No Healthcheck in Dockerfiles (4.6)
[WARN] No Healthcheck found: [ubuntu:latest]

This is relevant only for long-running containers or services where health monitoring matters (e.g. web app, DB, API server).

✅ You can ignore for test containers like hello-world, but if you build services, consider:

Dockerfile
Copy
Edit
HEALTHCHECK CMD curl -f http://localhost/ || exit 1
⚠️ 8. Content Trust is Disabled (4.5)
[WARN] Ensure Content trust for Docker is Enabled

Docker Content Trust (DCT) ensures images are signed. It's great for production pipelines, but:

✅ You can skip this in WSL/sandbox use. Just avoid pulling unverified images.

🧾 Final Score: -2
Totally reasonable for a rootless dev sandbox. The tool is built with rootful prod in mind.