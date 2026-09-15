# wsl_conf_update.sh – Annotated Guide
*Updated: 14 Sep 2026*

Installs or replaces the **managed block** in `/etc/wsl.conf`. The block comes from
`wsl_insert-<mode>.conf` next to the script and is written between two marker lines,
so re-running the script replaces the block in place instead of appending a second copy.

```bash
sudo ./wsl_conf_update.sh                   # mode ro (default)
sudo ./wsl_conf_update.sh --mode isolated   # only the VS Code extensions folder from C:, no Windows interop
sudo ./wsl_conf_update.sh --mode isolated --dry-run
```

In `isolated` mode the script also manages one entry in `/etc/fstab` and creates its mount point.

Follow every real run with `wsl --shutdown` from PowerShell or CMD. WSL reads the file only at boot.

---

## Modes

| Mode | `/mnt/c` | Windows `.exe` from Linux | `code .` from Windows Terminal | `code .` / `just code` in VS Code terminal | VS Code Remote WSL |
|------|----------|---------------------------|-------------------------------|--------------------------------------------|--------------------|
| `ro` (default) | read-only | yes | yes | yes | yes |
| `isolated` | only `Users/<you>/.vscode/extensions`, read-only | no | **no** | yes | yes |

VS Code Remote WSL needs one thing from C:: its bootstrap script `scripts/wslServer.sh`,
which the Windows client runs out of the extension folder via a path translated to
`/mnt/c/...`. WSL only translates paths that fall under a drvfs mount, so with automount
off the connection fails with `wsl: Failed to translate`. `isolated` mode therefore mounts
just that folder, read-only, through `/etc/fstab` (`mountFsTab = true`). Mounting the parent
`extensions` folder rather than the versioned extension directory survives extension updates.
Verified 2026-09-15 on Windows build 26200 with Remote WSL 0.104.3.

Inside a connected window's integrated terminal, `code` resolves to
`~/.vscode-server/bin/<commit>/bin/remote-cli/code`, a Linux script that forwards
`--folder-uri` requests to the open window. That is what `scripts/code-attach.sh`
(`just code <profile> <repo>`) uses, so it keeps working under `isolated`.

What `isolated` removes: `explorer.exe .`, `clip.exe`, `powershell.exe`, Windows-installed
toolchains on `$PATH` (Java, dotnet, chocolatey, oh-my-posh), and any git credential helper
that points at a Windows `.exe`. Check with `git config --global --get-all credential.helper`
before switching.

See `wsl_insert-guide.md` for the settings themselves.

---

## Flags

| Flag | Effect |
|------|--------|
| `--mode ro\|isolated` | Which `wsl_insert-<mode>.conf` to install. Default `ro`. |
| `--win-user NAME` | Windows user whose `.vscode\extensions` folder to mount in `isolated` mode. Default: the invoking user (`$SUDO_USER`). |
| `--fstab FILE` | Operate on `FILE` instead of `/etc/fstab`. For testing on a copy. |
| `--dry-run` | Print the resulting file to stdout. Writes nothing, needs no `sudo`. |
| `--conf FILE` | Operate on `FILE` instead of `/etc/wsl.conf`. For testing on a copy. |
| `-h`, `--help` | Usage. |

---

## What a run does

1. **Reports the installed block.** One of `mode=ro`, `mode=isolated`, `pre-marker install`, or `none`.
2. **Strips the old block.** Everything between `# >>> windows-ai-sandbox wsl.conf …` and
   `# <<< windows-ai-sandbox wsl.conf <<<` is dropped. Sections outside the markers
   (`[boot]`, `[user]`, …) are untouched.
3. **Refuses duplicates.** If an `[automount]`, `[network]` or `[interop]` section exists
   *outside* the markers the script stops, because WSL does not define which copy wins.
   Merge or remove it by hand, then re-run.
4. **Composes `/etc/fstab`.** Any previous entry under the
   `# windows-ai-sandbox: vscode extensions (isolated mode)` tag line is removed. In
   `isolated` mode a fresh tag line plus entry is appended:
   `C:\Users\<you>\.vscode\extensions /mnt/c/Users/<you>/.vscode/extensions drvfs ro,uid=…,gid=…,umask=22,fmask=11 0 0`.
   If `/mnt/c` is mounted right now the script checks that folder exists and stops if not
   (wrong `--win-user`).
5. **Compares.** If both files already match (ignoring the timestamp in the begin marker)
   and the mount point exists, it prints "Nothing to do" and exits 0.
6. **Backs up** each changed file to `<file>.bak.<timestamp>`, writes it, `chmod 644`,
   creates the mount point directory in `isolated` mode, and prints unified diffs.
7. **Reminds** you to `wsl --shutdown`, with extra warnings in `isolated` mode including
   how to get back to `ro` from a Windows Terminal Ubuntu tab if VS Code will not connect.

---

## Migration from the pre-marker install

Installs made before Sep 2026 have no end marker, only a banner line
`# --- Added by add-wsl-conf.sh (…) ---` followed by the three sections. The script
recognises that banner and replaces it and everything after it. That is safe because the
old script only ever appended to the end of the file. The run reports
`migrated pre-marker install -> mode=<mode>`.

---

## Verifying

Before a real run, preview on a copy of the live file:

```bash
cp /etc/wsl.conf "$TMPDIR/wsl.conf"
./wsl_conf_update.sh --mode isolated --dry-run --conf "$TMPDIR/wsl.conf"
```

After `wsl --shutdown` and reopening, in `ro` mode `mount | grep /mnt/c` shows `ro` and
`touch /mnt/c/x` fails with "Read-only file system". In `isolated` mode `ls /mnt/c` shows
only `Users`, `mount | grep drvfs` shows the single extensions mount, `wslpath -u 'C:\Windows'`
refuses to translate, and `which code` in a VS Code integrated terminal still points into
`~/.vscode-server`.

To try the narrow mount without changing config, on a running `ro` system:

```bash
sudo umount -l /mnt/c            # lazy: VS Code server processes have their cwd on it
sudo mkdir -p /mnt/c/Users/<you>/.vscode/extensions
sudo mount -t drvfs 'C:\Users\<you>\.vscode\extensions' /mnt/c/Users/<you>/.vscode/extensions -o ro,uid=1000,gid=1000,umask=22,fmask=11
```

then close the VS Code WSL window and reconnect. `wsl --shutdown` undoes it.

---

## Rolling back

```bash
sudo cp /etc/wsl.conf.bak.<timestamp> /etc/wsl.conf
```

then `wsl --shutdown`. Or run the script again with the other `--mode`, which also removes
the fstab entry when going back to `ro`.

*(End of document)*
