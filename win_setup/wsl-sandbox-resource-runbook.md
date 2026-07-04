# WSL Sandbox — Resource Changes Runbook

> **Transfer this to `C:\Users\nelly\` (or anywhere on the Windows side) so it is
> reachable while WSL is shut down / being reset.** Lives in the repo at
> `win_setup/wsl-sandbox-resource-runbook.md`. Date: 2026-06-23.

Repo: `~/repo/sandbox/windows-ai-sandbox` (inside WSL).

---

## What changed and why

A Jupyter kernel was dying instantly with
`Resource temporarily unavailable (src/thread.cpp:241)` — the container had run
out of PID/thread slots (cgroup `pids.max = 512`). gitstatusd was spawning ~32
threads per shell (sized to 16 host CPUs while the container only gets `cpus:4`),
and several VS Code windows stacked Node extension hosts on top. Four edits fix
it; two need manual action from **Windows**.

| File (in repo) | Change |
|---|---|
| `win_setup/.wslconfig` | `memory=48GB`, `swap=16GB` (VM was defaulting to 32GB = 50% of host) |
| `docker-compose.yml` | `pids_limit: 512→4096`, `mem_limit: 8g→20g`, `memswap_limit: 8g→20g` |
| `sandbox_templates/common/.zshrc` | `export GITSTATUS_NUM_THREADS=4` |
| `CLAUDE.md` | Resources row updated to match |

---

## STEP A — Activate the WSL memory bump (Windows side, REQUIRED)

The repo file is just the source copy. WSL reads `.wslconfig` from your Windows
profile, so it must be copied to `C:\Users\nelly\.wslconfig`.

1. **Close** all VS Code windows and WSL terminals (the shutdown kills them).
2. Put the config in place. Either:
   - From a WSL terminal (before shutting down):
     ```bash
     cp ~/repo/sandbox/windows-ai-sandbox/win_setup/.wslconfig /mnt/c/Users/nelly/.wslconfig
     ```
   - Or, if WSL is already down / was reset, paste this into
     `C:\Users\nelly\.wslconfig` with Notepad:
     ```ini
     # force traffic to use Windows/3rd party Firewall (e.g. Norton)
     [wsl2]
     networkingMode=mirrored
     memory=48GB
     swap=16GB
     ```
3. From **Windows PowerShell or CMD** (NOT inside WSL):
   ```powershell
   wsl --shutdown
   ```
4. Reopen WSL and confirm the VM grew:
   ```bash
   grep MemTotal /proc/meminfo      # expect ~48G (was ~32G)
   ```

---

## STEP B — Apply the container limits (inside WSL)

`pids_limit` / `mem_limit` are create-time, so each profile must be recreated:
```bash
cd ~/repo/sandbox/windows-ai-sandbox
scripts/profile.sh <profile> down
scripts/profile.sh <profile> up
```
The `GITSTATUS_NUM_THREADS` change is baked into the image, so to pick it up:
```bash
scripts/profile.sh build              # rebuild shared image
scripts/profile.sh <profile> rebuild  # recreate this profile on the new image
```
(Quick check without a rebuild: in a running shell, `export GITSTATUS_NUM_THREADS=4`
and open a fresh terminal.)

Order: do STEP A first (it restarts everything), then STEP B.

---

## STEP C — Reclaim disk (anytime, no restart)

The rootless docker data dir had grown to ~189GB (build cache). On the WSL host:
```bash
docker buildx prune          # build cache — biggest reclaim
docker image prune           # dangling layers
docker system df             # see what remains
```
Do NOT use `--volumes` or `-a` unless you intend to drop DB volumes / force a full
image rebuild. Keep `windows-ai-sandbox:latest`.

The WSL `.vhdx` grows but never auto-shrinks. To compact it (optional), from
elevated PowerShell after `wsl --shutdown`:
```powershell
# Hyper-V available:
Optimize-VHD -Path "<path-to-distro>\ext4.vhdx" -Mode Full
# else use: diskpart  →  select vdisk file="..."  →  compact vdisk
```

---

## If you FULLY reset/unregistered WSL (not just shutdown)

The repo lives inside the WSL filesystem and is gone after an unregister. After
reinstalling the distro:
1. Restore `~/repo/sandbox/windows-ai-sandbox` from git / your backup.
2. Re-run `host_setup/` (rootless Docker, `wsl_conf_update.sh`) per `CLAUDE.md`.
3. Then follow STEP A → B → C above.
Keep a copy of this file on `C:\` so it survives.

---

## Verify the original problem is gone
Open a notebook on the profile's venv; the kernel should start. Or inside an
attached agent:
```bash
cat /sys/fs/cgroup/pids.max /sys/fs/cgroup/pids.current   # max now 4096
```

## Sibling repo (macolima)
A scaled-down version of these recommendations is staged at
`~/repo/sandbox/macolima/MACOLIMA_in-transit_resource-limits-recommendations.md`
— macolima's Colima VM is only 10GB, so the numbers there are deliberately
smaller. Do not copy 20g / 4096 onto it.
