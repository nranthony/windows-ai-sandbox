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
mountFsTab = false

[network]
generateHosts = true
generateResolvConf = true

[interop]
enabled = false
appendWindowsPath = false
```

| Key | Purpose |
|-----|---------|
| `automount enabled = false` | No `/mnt/<drive>` at all. Linux cannot read C:, not even as root. |
| `interop enabled = false` | The kernel `binfmt_misc` handler for `.exe` is not registered. Linux cannot ask Windows to run anything. |
| `appendWindowsPath = false` | No Windows directories on `$PATH`. Also speeds up shell startup and command lookup. |

Still works: VS Code Remote WSL, `code .` and `just code <profile> <repo>` from a VS Code
integrated terminal, Windows reading the Linux filesystem via `\\wsl$\<distro>`, localhost
port forwarding, `wsl.exe` commands issued from Windows.

Stops working: `code .` from Windows Terminal, `clip.exe` / `explorer.exe` / `powershell.exe`,
Windows-installed Java / dotnet / chocolatey / oh-my-posh on `$PATH`, git credential helpers
that point at a Windows `.exe`. Install Linux equivalents where needed.

---

## Why VS Code does not need interop or `/mnt/c`

The Remote WSL extension runs its server inside the Linux filesystem at `~/.vscode-server`.
The Windows client starts it with `wsl.exe -d <distro>` and talks to it over a pipe. Server
updates are downloaded from inside WSL. Nothing in that path crosses `/mnt/c`, and interop is
only needed for the reverse direction, Linux launching Windows programs.

---

## Which mode?

`ro` is the balance for day-to-day use: Windows files readable, nothing writable.
`isolated` is for when you want a container escape to see no Windows filesystem at all
and be unable to start a Windows process. It is the stronger boundary, at the cost of the
conveniences listed above. Switching is one `wsl_conf_update.sh --mode …` run plus
`wsl --shutdown`.

*(End of document)*
