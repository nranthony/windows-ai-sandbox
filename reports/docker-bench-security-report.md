```md
# --------------------------------------------------------------------------------------------
# Docker Bench for Security v1.6.0
#
# Docker, Inc. (c) 2015-2025
#
# Checks for dozens of common best-practices around deploying Docker containers in production.
# Based on the CIS Docker Benchmark 1.6.0.
# --------------------------------------------------------------------------------------------
```
$\color{red}{\textsf{[WARN]}}$ Some tests might require root to run<br>

Initializing 2025-06-23T12:51:05-04:00<br>


Section A - Check results<br>

$\color{blue}{\textsf{[INFO]}}$ 1 - Host Configuration<br>
$\color{blue}{\textsf{[INFO]}}$ 1.1 - Linux Hosts Specific Configuration<br>
WARNING: No cpuset support<br>
WARNING: No io.weight support<br>
WARNING: No io.weight (per device) support<br>
WARNING: No io.max (rbps) support<br>
WARNING: No io.max (wbps) support<br>
WARNING: No io.max (riops) support<br>
WARNING: No io.max (wiops) support<br>
$\color{red}{\textsf{[WARN]}}$ 1.1.1 - Ensure a separate partition for containers has been created (Automated)<br>
$\color{blue}{\textsf{[INFO]}}$ 1.1.2 - Ensure only trusted users are allowed to control Docker daemon (Automated)<br>
$\color{blue}{\textsf{[INFO]}}$       * Users:<br>
You must be root to run this program.<br>
$\color{red}{\textsf{[WARN]}}$ 1.1.3 - Ensure auditing is configured for the Docker daemon (Automated)<br>
You must be root to run this program.<br>
$\color{red}{\textsf{[WARN]}}$ 1.1.4 - Ensure auditing is configured for Docker files and directories -/run/containerd (Automated)<br>
You must be root to run this program.<br>
$\color{red}{\textsf{[WARN]}}$ 1.1.5 - Ensure auditing is configured for Docker files and directories - /var/lib/docker (Automated)<br>
You must be root to run this program.<br>
$\color{red}{\textsf{[WARN]}}$ 1.1.6 - Ensure auditing is configured for Docker files and directories - /etc/docker (Automated)<br>
You must be root to run this program.<br>
$\color{red}{\textsf{[WARN]}}$ 1.1.7 - Ensure auditing is configured for Docker files and directories - docker.service (Automated)<br>
$\color{blue}{\textsf{[INFO]}}$ 1.1.8 - Ensure auditing is configured for Docker files and directories - containerd.sock (Automated)<br>
$\color{blue}{\textsf{[INFO]}}$        * File not found<br>
You must be root to run this program.<br>
$\color{red}{\textsf{[WARN]}}$ 1.1.9 - Ensure auditing is configured for Docker files and directories - docker.socket (Automated)<br>
You must be root to run this program.<br>
$\color{red}{\textsf{[WARN]}}$ 1.1.10 - Ensure auditing is configured for Docker files and directories - /etc/default/docker (Automated)<br>
You must be root to run this program.<br>
$\color{red}{\textsf{[WARN]}}$ 1.1.11 - Ensure auditing is configured for Dockerfiles and directories - /etc/docker/daemon.json (Automated)<br>
You must be root to run this program.<br>
$\color{red}{\textsf{[WARN]}}$ 1.1.12 - 1.1.12 Ensure auditing is configured for Dockerfiles and directories - /etc/containerd/config.toml (Automated)<br>
$\color{blue}{\textsf{[INFO]}}$ 1.1.13 - Ensure auditing is configured for Docker files and directories - /etc/sysconfig/docker (Automated)<br>
$\color{blue}{\textsf{[INFO]}}$        * File not found<br>
You must be root to run this program.<br>
$\color{red}{\textsf{[WARN]}}$ 1.1.14 - Ensure auditing is configured for Docker files and directories - /usr/bin/containerd (Automated)<br>
You must be root to run this program.<br>
$\color{red}{\textsf{[WARN]}}$ 1.1.15 - Ensure auditing is configured for Docker files and directories - /usr/bin/containerd-shim (Automated)<br>
You must be root to run this program.<br>
$\color{red}{\textsf{[WARN]}}$ 1.1.16 - Ensure auditing is configured for Docker files and directories - /usr/bin/containerd-shim-runc-v1 (Automated)<br>
You must be root to run this program.<br>
$\color{red}{\textsf{[WARN]}}$ 1.1.17 - Ensure auditing is configured for Docker files and directories - /usr/bin/containerd-shim-runc-v2 (Automated)<br>
You must be root to run this program.<br>
$\color{red}{\textsf{[WARN]}}$ 1.1.18 - Ensure auditing is configured for Docker files and directories - /usr/bin/runc (Automated)<br>
$\color{blue}{\textsf{[INFO]}}$ 1.2 - General Configuration<br>
$\color{yellow}{\textsf{[NOTE]}}$ 1.2.1 - Ensure the container host has been Hardened (Manual)<br>
$\color{green}{\textsf{[PASS]}}$ 1.2.2 - Ensure that the version of Docker is up to date (Manual)<br>
$\color{blue}{\textsf{[INFO]}}$        * Using 28.2.2 which is current<br>
$\color{blue}{\textsf{[INFO]}}$        * Check with your operating system vendor for support and security maintenance for Docker<br>

$\color{blue}{\textsf{[INFO]}}$ 2 - Docker daemon configuration<br>
$\color{yellow}{\textsf{[NOTE]}}$ 2.1 - Run the Docker daemon as a non-root user, if possible (Manual)<br>
$\color{red}{\textsf{[WARN]}}$ 2.2 - Ensure network traffic is restricted between containers on the default bridge (Scored)<br>
$\color{green}{\textsf{[PASS]}}$ 2.3 - Ensure the logging level is set to 'info' (Scored)<br>
$\color{green}{\textsf{[PASS]}}$ 2.4 - Ensure Docker is allowed to make changes to iptables (Scored)<br>
$\color{green}{\textsf{[PASS]}}$ 2.5 - Ensure insecure registries are not used (Scored)<br>
$\color{green}{\textsf{[PASS]}}$ 2.6 - Ensure aufs storage driver is not used (Scored)<br>
$\color{blue}{\textsf{[INFO]}}$ 2.7 - Ensure TLS authentication for Docker daemon is configured (Scored)<br>
$\color{blue}{\textsf{[INFO]}}$      * Docker daemon not listening on TCP<br>
$\color{green}{\textsf{[PASS]}}$ 2.8 - Ensure the default ulimit is configured appropriately (Manual)<br>
$\color{red}{\textsf{[WARN]}}$ 2.9 - Enable user namespace support (Scored)<br>
$\color{green}{\textsf{[PASS]}}$ 2.10 - Ensure the default cgroup usage has been confirmed (Scored)<br>
$\color{green}{\textsf{[PASS]}}$ 2.11 - Ensure base device size is not changed until needed (Scored)<br>
$\color{red}{\textsf{[WARN]}}$ 2.12 - Ensure that authorization for Docker client commands is enabled (Scored)<br>
$\color{red}{\textsf{[WARN]}}$ 2.13 - Ensure centralized and remote logging is configured (Scored)<br>
$\color{green}{\textsf{[PASS]}}$ 2.14 - Ensure containers are restricted from acquiring new privileges (Scored)<br>
$\color{red}{\textsf{[WARN]}}$ 2.15 - Ensure live restore is enabled (Scored)<br>
$\color{red}{\textsf{[WARN]}}$ 2.16 - Ensure Userland Proxy is Disabled (Scored)<br>
$\color{blue}{\textsf{[INFO]}}$ 2.17 - Ensure that a daemon-wide custom seccomp profile is applied if appropriate (Manual)<br>
$\color{blue}{\textsf{[INFO]}}$ Ensure that experimental features are not implemented in production (Scored) (Deprecated)<br>

$\color{blue}{\textsf{[INFO]}}$ 3 - Docker daemon configuration files<br>
$\color{green}{\textsf{[PASS]}}$ 3.1 - Ensure that the docker.service file ownership is set to root:root (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 3.2 - Ensure that docker.service file permissions are appropriately set (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 3.3 - Ensure that docker.socket file ownership is set to root:root (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 3.4 - Ensure that docker.socket file permissions are set to 644 or more restrictive (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 3.5 - Ensure that the /etc/docker directory ownership is set to root:root (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 3.6 - Ensure that /etc/docker directory permissions are set to 755 or more restrictively (Automated)<br>
$\color{blue}{\textsf{[INFO]}}$ 3.7 - Ensure that registry certificate file ownership is set to root:root (Automated)<br>
$\color{blue}{\textsf{[INFO]}}$      * Directory not found<br>
$\color{blue}{\textsf{[INFO]}}$ 3.8 - Ensure that registry certificate file permissions are set to 444 or more restrictively (Automated)<br>
$\color{blue}{\textsf{[INFO]}}$      * Directory not found<br>
$\color{blue}{\textsf{[INFO]}}$ 3.9 - Ensure that TLS CA certificate file ownership is set to root:root (Automated)<br>
$\color{blue}{\textsf{[INFO]}}$      * No TLS CA certificate found<br>
$\color{blue}{\textsf{[INFO]}}$ 3.10 - Ensure that TLS CA certificate file permissions are set to 444 or more restrictively (Automated)<br>
$\color{blue}{\textsf{[INFO]}}$       * No TLS CA certificate found<br>
$\color{blue}{\textsf{[INFO]}}$ 3.11 - Ensure that Docker server certificate file ownership is set to root:root (Automated)<br>
$\color{blue}{\textsf{[INFO]}}$       * No TLS Server certificate found<br>
$\color{blue}{\textsf{[INFO]}}$ 3.12 - Ensure that the Docker server certificate file permissions are set to 444 or more restrictively (Automated)<br>
$\color{blue}{\textsf{[INFO]}}$       * No TLS Server certificate found<br>
$\color{blue}{\textsf{[INFO]}}$ 3.13 - Ensure that the Docker server certificate key file ownership is set to root:root (Automated)<br>
$\color{blue}{\textsf{[INFO]}}$       * No TLS Key found<br>
$\color{blue}{\textsf{[INFO]}}$ 3.14 - Ensure that the Docker server certificate key file permissions are set to 400 (Automated)<br>
$\color{blue}{\textsf{[INFO]}}$       * No TLS Key found<br>
$\color{blue}{\textsf{[INFO]}}$ 3.15 - Ensure that the Docker socket file ownership is set to root:docker (Automated)<br>
$\color{blue}{\textsf{[INFO]}}$       * File not found<br>
$\color{blue}{\textsf{[INFO]}}$ 3.16 - Ensure that the Docker socket file permissions are set to 660 or more restrictively (Automated)<br>
$\color{blue}{\textsf{[INFO]}}$       * File not found<br>
$\color{green}{\textsf{[PASS]}}$ 3.17 - Ensure that the daemon.json file ownership is set to root:root (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 3.18 - Ensure that daemon.json file permissions are set to 644 or more restrictive (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 3.19 - Ensure that the /etc/default/docker file ownership is set to root:root (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 3.20 - Ensure that the /etc/default/docker file permissions are set to 644 or more restrictively (Automated)<br>
$\color{blue}{\textsf{[INFO]}}$ 3.21 - Ensure that the /etc/sysconfig/docker file permissions are set to 644 or more restrictively (Automated)<br>
$\color{blue}{\textsf{[INFO]}}$       * File not found<br>
$\color{blue}{\textsf{[INFO]}}$ 3.22 - Ensure that the /etc/sysconfig/docker file ownership is set to root:root (Automated)<br>
$\color{blue}{\textsf{[INFO]}}$       * File not found<br>
$\color{green}{\textsf{[PASS]}}$ 3.23 - Ensure that the Containerd socket file ownership is set to root:root (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 3.24 - Ensure that the Containerd socket file permissions are set to 660 or more restrictively (Automated)<br>

$\color{blue}{\textsf{[INFO]}}$ 4 - Container Images and Build File<br>
$\color{red}{\textsf{[WARN]}}$ 4.1 - Ensure that a user for the container has been created (Automated)<br>
$\color{red}{\textsf{[WARN]}}$      * Running as root: elated_lehmann<br>
$\color{yellow}{\textsf{[NOTE]}}$ 4.2 - Ensure that containers use only trusted base images (Manual)<br>
$\color{yellow}{\textsf{[NOTE]}}$ 4.3 - Ensure that unnecessary packages are not installed in the container (Manual)<br>
$\color{yellow}{\textsf{[NOTE]}}$ 4.4 - Ensure images are scanned and rebuilt to include security patches (Manual)<br>
$\color{red}{\textsf{[WARN]}}$ 4.5 - Ensure Content trust for Docker is Enabled (Automated)<br>
$\color{red}{\textsf{[WARN]}}$ 4.6 - Ensure that HEALTHCHECK instructions have been added to container images (Automated)<br>
$\color{red}{\textsf{[WARN]}}$      * No Healthcheck found: [nvidia/cuda:12.9.0-base-ubuntu24.04]<br>
$\color{blue}{\textsf{[INFO]}}$ 4.7 - Ensure update instructions are not used alone in the Dockerfile (Manual)<br>
$\color{blue}{\textsf{[INFO]}}$      * Update instruction found: [vsc-windows-ai-sandbox-11dd5be27547e71e11466b943c2c23ce7d7020739c4281bec579479d0caa3946:latest]<br>
$\color{yellow}{\textsf{[NOTE]}}$ 4.8 - Ensure setuid and setgid permissions are removed (Manual)<br>
$\color{blue}{\textsf{[INFO]}}$ 4.9 - Ensure that COPY is used instead of ADD in Dockerfiles (Manual)<br>
$\color{blue}{\textsf{[INFO]}}$      * ADD in image history: [vsc-windows-ai-sandbox-11dd5be27547e71e11466b943c2c23ce7d7020739c4281bec579479d0caa3946:latest]<br>
$\color{blue}{\textsf{[INFO]}}$      * ADD in image history: [nvidia/cuda:12.9.0-base-ubuntu24.04]<br>
$\color{yellow}{\textsf{[NOTE]}}$ 4.10 - Ensure secrets are not stored in Dockerfiles (Manual)<br>
$\color{yellow}{\textsf{[NOTE]}}$ 4.11 - Ensure only verified packages are installed (Manual)<br>
$\color{yellow}{\textsf{[NOTE]}}$ 4.12 - Ensure all signed artifacts are validated (Manual)<br>

$\color{blue}{\textsf{[INFO]}}$ 5 - Container Runtime<br>
$\color{green}{\textsf{[PASS]}}$ 5.1 - Ensure swarm mode is not Enabled, if not needed (Automated)<br>
$\color{red}{\textsf{[WARN]}}$ 5.2 - Ensure that, if applicable, an AppArmor Profile is enabled (Automated)<br>
$\color{red}{\textsf{[WARN]}}$      * No AppArmorProfile Found: elated_lehmann<br>
$\color{green}{\textsf{[PASS]}}$ 5.3 - Ensure that, if applicable, SELinux security options are set (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 5.4 - Ensure that Linux kernel capabilities are restricted within containers (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 5.5 - Ensure that privileged containers are not used (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 5.6 - Ensure sensitive host system directories are not mounted on containers (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 5.7 - Ensure sshd is not run within containers (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 5.8 - Ensure privileged ports are not mapped within containers (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 5.9 - Ensure that only needed ports are open on the container (Manual)<br>
$\color{green}{\textsf{[PASS]}}$ 5.10 - Ensure that the host's network namespace is not shared (Automated)<br>
$\color{red}{\textsf{[WARN]}}$ 5.11 - Ensure that the memory usage for containers is limited (Automated)<br>
$\color{red}{\textsf{[WARN]}}$       * Container running without memory restrictions: elated_lehmann<br>
$\color{red}{\textsf{[WARN]}}$ 5.12 - Ensure that CPU priority is set appropriately on containers (Automated)<br>
$\color{red}{\textsf{[WARN]}}$       * Container running without CPU restrictions: elated_lehmann<br>
$\color{red}{\textsf{[WARN]}}$ 5.13 - Ensure that the container's root filesystem is mounted as read only (Automated)<br>
$\color{red}{\textsf{[WARN]}}$       * Container running with root FS mounted R/W: elated_lehmann<br>
$\color{green}{\textsf{[PASS]}}$ 5.14 - Ensure that incoming container traffic is bound to a specific host interface (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 5.15 - Ensure that the 'on-failure' container restart policy is set to '5' (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 5.16 - Ensure that the host's process namespace is not shared (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 5.17 - Ensure that the host's IPC namespace is not shared (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 5.18 - Ensure that host devices are not directly exposed to containers (Manual)<br>
$\color{blue}{\textsf{[INFO]}}$ 5.19 - Ensure that the default ulimit is overwritten at runtime if needed (Manual)<br>
$\color{blue}{\textsf{[INFO]}}$       * Container no default ulimit override: elated_lehmann<br>
$\color{green}{\textsf{[PASS]}}$ 5.20 - Ensure mount propagation mode is not set to shared (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 5.21 - Ensure that the host's UTS namespace is not shared (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 5.22 - Ensure the default seccomp profile is not Disabled (Automated)<br>
$\color{yellow}{\textsf{[NOTE]}}$ 5.23 - Ensure that docker exec commands are not used with the privileged option (Automated)<br>
$\color{yellow}{\textsf{[NOTE]}}$ 5.24 - Ensure that docker exec commands are not used with the user=root option (Manual)<br>
$\color{green}{\textsf{[PASS]}}$ 5.25 - Ensure that cgroup usage is confirmed (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 5.26 - Ensure that the container is restricted from acquiring additional privileges (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 5.27 - Ensure that container health is checked at runtime (Automated)<br>
$\color{blue}{\textsf{[INFO]}}$ 5.28 - Ensure that Docker commands always make use of the latest version of their image (Manual)<br>
$\color{red}{\textsf{[WARN]}}$ 5.29 - Ensure that the PIDs cgroup limit is used (Automated)<br>
$\color{red}{\textsf{[WARN]}}$       * PIDs limit not set: elated_lehmann<br>
$\color{green}{\textsf{[PASS]}}$ 5.30 - Ensure that Docker's default bridge 'docker0' is not used (Manual)<br>
$\color{green}{\textsf{[PASS]}}$ 5.31 - Ensure that the host's user namespaces are not shared (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 5.32 - Ensure that the Docker socket is not mounted inside any containers (Automated)<br>

$\color{blue}{\textsf{[INFO]}}$ 6 - Docker Security Operations<br>
$\color{blue}{\textsf{[INFO]}}$ 6.1 - Ensure that image sprawl is avoided (Manual)<br>
$\color{blue}{\textsf{[INFO]}}$      * There are currently: 2 images<br>
$\color{blue}{\textsf{[INFO]}}$ 6.2 - Ensure that container sprawl is avoided (Manual)<br>
$\color{blue}{\textsf{[INFO]}}$      * There are currently a total of 1 containers, with 1 of them currently running<br>

$\color{blue}{\textsf{[INFO]}}$ 7 - Docker Swarm Configuration<br>
$\color{green}{\textsf{[PASS]}}$ 7.1 - Ensure that the minimum number of manager nodes have been created in a swarm (Automated) (Swarm mode not enabled)<br>
$\color{green}{\textsf{[PASS]}}$ 7.2 - Ensure that swarm services are bound to a specific host interface (Automated) (Swarm mode not enabled)<br>
$\color{green}{\textsf{[PASS]}}$ 7.3 - Ensure that all Docker swarm overlay networks are encrypted (Automated)<br>
$\color{green}{\textsf{[PASS]}}$ 7.4 - Ensure that Docker's secret management commands are used for managing secrets in a swarm cluster (Manual) (Swarm mode not enabled)<br>
$\color{green}{\textsf{[PASS]}}$ 7.5 - Ensure that swarm manager is run in auto-lock mode (Automated) (Swarm mode not enabled)<br>
$\color{green}{\textsf{[PASS]}}$ 7.6 - Ensure that the swarm manager auto-lock key is rotated periodically (Manual) (Swarm mode not enabled)<br>
$\color{green}{\textsf{[PASS]}}$ 7.7 - Ensure that node certificates are rotated as appropriate (Manual) (Swarm mode not enabled)<br>
$\color{green}{\textsf{[PASS]}}$ 7.8 - Ensure that CA certificates are rotated as appropriate (Manual) (Swarm mode not enabled)<br>
$\color{green}{\textsf{[PASS]}}$ 7.9 - Ensure that management plane traffic is separated from data plane traffic (Manual) (Swarm mode not enabled)<br>


Section C - Score<br>

$\color{blue}{\textsf{[INFO]}}$ Checks: 117<br>
$\color{blue}{\textsf{[INFO]}}$ Score: 15


<br>


# ChatGPT summary of results in context of rootless docker inside WSL:

# Docker Sandbox Security Status Report

## Overview
This report summarizes the current security posture of your **rootless** Docker setup in WSL2, with the Windows 11 host mounted read-only. The environment runs a single, hand-crafted container at a time, with an active developer interacting directly.

## What's Working Well
- **Rootless Docker in WSL2**  
  Containers operate without root access on the Linux host. The Windows 11 filesystem is mounted read-only, preventing container processes from tampering with host files.

- **Auditd Rules in Place**  
  Key Docker-related binaries (containerd, runc) and configuration directories (`/etc/docker`, `/var/lib/docker`, `/etc/containerd/config.toml`) are audited. Any execution or write is logged for forensic review.

- **Live-Restore Enabled**  
  The Docker daemon’s `live-restore` setting keeps your devcontainer running across daemon restarts or configuration reloads, preserving development sessions.

- **Docker Content Trust**  
  Enforced via environment variable so that only signed images are pulled and run, safeguarding against malicious or tampered images.

- **Non-Root App User**  
  Dockerfiles create a dedicated non-root user (`appuser`) before switching the default user. This reduces privileges if an escape occurs.

- **AppArmor Confinement**  
  The default `docker-default` AppArmor profile is loaded in WSL2, applying kernel-level syscall restrictions on containers.

- **HEALTHCHECK Configured**  
  Your Dockerfile includes:
  ```dockerfile
  HEALTHCHECK --interval=60s --timeout=3s \
    CMD curl -f http://localhost/health || exit 1
  ```
  ensuring automatic detection of container health.

## Future Improvement Areas
- **Resource Quotas** (memory, CPU, PIDs): Prevent runaway processes from affecting the host.
- **Read-Only Root Filesystem**: Mount container rootfs read-only for additional write protection.
- **Custom Seccomp Profile**: Whitelist only the syscalls your workload uses to shrink the kernel attack surface.
- **Internal Network Isolation**: Disable the `bridge` network or create an isolated Docker network for enhanced containment.
- **API Authorization**: Add an authorization plugin (e.g., OPA) to control which Docker commands can run.
- **Centralized Logging**: Forward logs to a local log aggregator for easy audit and incident response.
- **Automated Cleanup**: Schedule pruning of stopped containers and unused images to keep the sandbox tidy.

## Conclusion
Your rootless, single-container WSL2 sandbox—backed by read-only host mounts, auditing, and runtime confinement—provides a robust baseline. By layering in targeted resource limits, network isolation, and custom syscall filters over time, you can further elevate security without sacrificing your interactive workflow.