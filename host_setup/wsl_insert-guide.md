# wsl_insert.conf – Annotated Guide  
*Updated: 23 Jun 2025*

`wsl_insert.conf` is a reusable snippet that hardens the Windows Subsystem for Linux **without** breaking popular tooling such as VS Code Remote or Docker Desktop.  
The accompanying `wsl_conf_update.sh` script appends this block to `/etc/wsl.conf`.

---

```ini
[automount]
enabled = true
options = "metadata,umask=22,fmask=11,ro"
mountFsTab = false
```

| Key | Purpose |
|-----|---------|
| `enabled = true` | Keeps Windows drives (C:, D:, …) available under `/mnt/` in WSL. |
| `options = … ro` | Mounts them **read‑only** so malware inside Linux cannot encrypt or delete Windows files. |
| `metadata` | Allows traditional Linux file permissions on NTFS. |
| `umask=22,fmask=11` | Default to 755 dirs / 644 files for shared readability. |
| `mountFsTab = false` | Prevents double‑mounting if you later add NTFS entries to `/etc/fstab`. |

---

```ini
[network]
generateHosts = true
generateResolvConf = true
```

Explicitly requests the defaults so future script readers can see the intention.

---

```ini
[interop]
enabled = true
appendWindowsPath = true
```

Keeps inter‑process communication (e.g. `code .`) functional and places Windows executables on the Linux `$PATH`.

---

## Why read‑only drives?  

* Ransomware or a rogue `rm -rf /mnt/c/Users` inside a container cannot damage Windows.  
* Improves WSL startup time when large drives are scanned as readable only.  
* You can temporarily remount read‑write for drag‑and‑drop sharing:

```bash
sudo mount -o remount,rw /mnt/c
```

*(End of document)*