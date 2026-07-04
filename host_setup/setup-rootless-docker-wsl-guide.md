# setup-rootless-docker-wsl.sh – Annotated Guide  
*Updated: 23 Jun 2025*

This document walks you through every major block in **`setup-rootless-docker-wsl.sh`**, explaining **what** each command does and **why** it is necessary when running an AI‑focused sandbox inside **WSL 2**.  
Only one container will run at a time, but we still apply best‑practice hardening so that accidental privilege escalation, noisy logs, or GPU breakage do not interrupt your workflow.

---

## 1. Script Preamble  

```bash
#!/bin/bash
set -e
```

* **`#!/bin/bash`** forces execution with Bash even if `/bin/sh` is another shell.  
* **`set -e`** aborts on the first non‑zero exit code — failing fast is critical during low‑level system setup.

---

## 2. Installing Prerequisites  

The first `apt-get` block pulls in:

| Package | Reason |
|---------|--------|
| `uidmap` | Enables user‑namespace remapping for **rootless** Docker. |
| `dbus-user-session` | Provides a per‑user D‑Bus bus that systemd‑user units rely on. |
| `ca-certificates`, `gnupg` | Secure package signing and HTTPS access. |
| `curl` | Fetches GPG keys and remote scripts. |
| Docker packages (`docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-compose-plugin`) | Core containers runtime & CLI. |

GPU hosts also add the **NVIDIA Container Toolkit** repository and package so that `--gpus all` is honoured from inside WSL.

> **Note** – the script auto-detects the GPU (`/dev/dxg` on WSL2, or `nvidia-smi` on bare Linux) and skips every NVIDIA step on hosts without one. Force either way with `SETUP_GPU=1` / `SETUP_GPU=0`.

---

## 3. Disabling the Rootful Daemon  

```bash
sudo systemctl disable --now docker.service docker.socket || true
```

Running the privileged daemon inside WSL is rarely required and can become a foot‑gun.  
Instead we will run Dockerd **rootless**, owned by your normal UNIX uid and listening on  
`unix:///run/user/UID/docker.sock`.

---

## 4. Enabling *linger* & Password‑less Restart  

```bash
sudo loginctl enable-linger "$USER"
```

`linger` allows your **systemd‑user** services (including Dockerd) to survive even when no interactive shell is open.  
The script then drops a very narrow sudoers snippet permitting:

```
%wheel ALL=(ALL) NOPASSWD: /bin/systemctl restart user@*.service
```

so that a helper in your `~/.profile` can fix a broken systemd session automatically without prompting for a password.

---

## 5. `dockerd-rootless-setuptool.sh install`  

This upstream installer creates:

* `~/.config/systemd/user/docker.service`  
* Helper binaries in `~/.local/bin` (`rootlesskit`, `vpnkit`, …)  
* A working **iptables** NAT setup on a high, unprivileged port.

The script immediately **moves** that service unit into `/etc/systemd/user/` so it survives `wsl --export` / `wsl --import` and keeps the file out of your dot‑files.

---

## 6. Securing `daemon.json`  

A minimal hardened config is placed in **`/etc/docker/daemon.json`**:

```jsonc
{
  "no-new-privileges": true,
  "live-restore": true,
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "storage-driver": "overlay2"
}
```

* `no-new-privileges` blocks `setuid` binaries inside containers.  
* `live-restore` keeps containers running if Dockerd restarts (handy during WSL shutdowns).  
* Log rotation prevents runaway disk usage on long‑running ML jobs.

---

## 7. Adding NVIDIA CDI & Runtime  

```bash
sudo nvidia-ctk runtime configure \
     --runtime=docker --config=/etc/docker/daemon.json \
     --nvidia-set-as-default --enable-cdi
```

This registers the NVIDIA runtime **for rootless Docker** and generates **Container Device Interface** manifests so that Kubernetes or other orchestration layers can discover the GPU later if you migrate away from one‑off containers.

---

## 8. Hardened Networking  

* Creates a dedicated user bridge `ai-sandbox` on `172.20.0.0/16`.  
* Injects an **`iptables` DOCKER-USER** chain dropping unsolicited traffic, allowing only established connections–and optionally SSH if you uncomment it.  
* Persists rules with `netfilter-persistent`.

---

## 9. Audit Rules  

To catch tampering, the script writes `/etc/audit/rules.d/docker.rules` with watches on:

* `/usr/bin/docker`, `dockerd`, and friends  
* `/etc/docker/`  

so any binary or config change is logged via **auditd**.

---

## 10. Smoke Test  

Finally, the script launches:

```bash
docker run --rm --gpus all nvidia/cuda:12.9.0-base-ubuntu24.04 nvidia-smi
```

Success output means CUDA inside a rootless container can see your GPU.

---

## 11. Safe Re‑runs  

All destructive actions are guarded with `if` checks (`[[ -f … ]]`, `systemctl is-enabled …`).  
You can safely re‑execute the script to pick up upstream updates.

---

## Summary  

Running Docker rootless inside WSL gives most of the isolation benefits of a VM without the overhead.  
This script automates the repetitive repository adds, service moves, and security tweaks so that new machines reach a hardened baseline in minutes.

*(End of document)*