# wsl_insert-*.conf – Annotated Guide
*Updated: 14 Sep 2026*

Two snippets, one per mode. `wsl_conf_update.sh --mode <mode>` installs the matching file
into `/etc/wsl.conf` between marker lines. Both keep VS Code Remote WSL and rootless Docker
working; they differ in how much of Windows is visible from Linux.

---

## `wsl_insert-ro.conf` (mode `ro`, default)

```ini
[automount]
enabled = true
options = "metadata,umask=22,fmask=11,ro"
mountFsTab = false

[network]
generateHosts = true
generateResolvConf = true

[interop]
enabled = true
appendWindowsPath = true
```

| Key | Purpose |
|-----|---------|
| `automount enabled = true` | Windows drives (C:, D:, …) appear under `/mnt/`. |
| `options = … ro` | Mounted **read-only**. Malware or a stray `rm -rf /mnt/c/Users` inside Linux cannot modify Windows files. |
| `metadata` | Traditional Linux permission bits on NTFS. |
| `umask=22,fmask=11` | 755 dirs / 644 files. |
| `mountFsTab = false` | No double-mounting if NTFS entries are later added to `/etc/fstab`. |
| `generateHosts`, `generateResolvConf` | WSL defaults, stated explicitly. |
| `interop enabled = true` | Linux can launch Windows `.exe` files (`clip.exe`, `explorer.exe`, `code`). |
| `appendWindowsPath = true` | Windows `PATH` entries are appended to the Linux `$PATH` as `/mnt/c/...`. |

Temporary read-write for drag-and-drop sharing: `sudo mount -o remount,rw /mnt/c`.
Reverts at the next `wsl --shutdown`.

---

## `wsl_insert-isolated.conf` (mode `isolated`)

```ini
[automount]
enabled = false
mountFsTab = true

[network]
generateHosts = true
generateResolvConf = true

[interop]
enabled = false
appendWindowsPath = false
```

plus one entry in `/etc/fstab`, written by `wsl_conf_update.sh`:

```
# windows-ai-sandbox: vscode extensions (isolated mode)
C:\Users\<you>\.vscode\extensions /mnt/c/Users/<you>/.vscode/extensions drvfs ro,uid=1000,gid=1000,umask=22,fmask=11 0 0
```

| Key | Purpose |
|-----|---------|
| `automount enabled = false` | No automatic `/mnt/<drive>`. C: is invisible except for the fstab entry below. |
| `mountFsTab = true` | WSL runs `mount -a` at boot, which brings in the extensions folder. |
| fstab entry | Read-only mount of the VS Code extensions folder only. Remote WSL runs `scripts/wslServer.sh` from there and WSL path translation needs a drvfs mount to resolve it. |
| `interop enabled = false` | The kernel `binfmt_misc` handler for `.exe` is not registered. Linux cannot ask Windows to run anything. |
| `appendWindowsPath = false` | No Windows directories on `$PATH`. Also speeds up shell startup and command lookup. |

Still works: VS Code Remote WSL, `code .` and `just code <profile> <repo>` from a VS Code
integrated terminal, Windows reading the Linux filesystem via `\\wsl$\<distro>`, localhost
port forwarding, `wsl.exe` commands issued from Windows.

Stops working: `code .` from Windows Terminal, `clip.exe` / `explorer.exe` / `powershell.exe`,
Windows-installed Java / dotnet / chocolatey / oh-my-posh on `$PATH`, git credential helpers
that point at a Windows `.exe`. Install Linux equivalents where needed.

---

## What VS Code actually needs from Windows

The Remote WSL extension runs its server inside the Linux filesystem at `~/.vscode-server`.
The Windows client starts it with `wsl.exe -d <distro>` and talks to it over a pipe. But the
bootstrap step runs `$VSCODE_WSL_EXT_LOCATION/scripts/wslServer.sh`, and that variable is the
extension folder on C: translated to a `/mnt/c/...` path. With no drvfs mount covering it,
the translation fails and the server never starts. A read-only mount of just
`C:\Users\<you>\.vscode\extensions` is sufficient (verified 2026-09-15). Interop is not
involved: it only matters for the reverse direction, Linux launching Windows programs.

---

## Which mode?

`ro` is the balance for day-to-day use: Windows files readable, nothing writable.
`isolated` is for when you want a container escape to see nothing of the Windows filesystem
beyond the VS Code extensions folder, and be unable to start a Windows process. It is the stronger boundary, at the cost of the
conveniences listed above. Switching is one `wsl_conf_update.sh --mode …` run plus
`wsl --shutdown`.

*(End of document)*
