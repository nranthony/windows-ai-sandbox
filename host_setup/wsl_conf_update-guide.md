# wsl_conf_update.sh – Annotated Guide
*Updated: 14 Sep 2026*

Installs or replaces the **managed block** in `/etc/wsl.conf`. The block comes from
`wsl_insert-<mode>.conf` next to the script and is written between two marker lines,
so re-running the script replaces the block in place instead of appending a second copy.

```bash
sudo ./wsl_conf_update.sh                   # mode ro (default)
sudo ./wsl_conf_update.sh --mode isolated   # no /mnt/c, no Windows interop
sudo ./wsl_conf_update.sh --mode isolated --dry-run
```

Follow every real run with `wsl --shutdown` from PowerShell or CMD. WSL reads the file only at boot.

---

## Modes

| Mode | `/mnt/c` | Windows `.exe` from Linux | `code .` from Windows Terminal | `code .` / `just code` in VS Code terminal | VS Code Remote WSL |
|------|----------|---------------------------|-------------------------------|--------------------------------------------|--------------------|
| `ro` (default) | read-only | yes | yes | yes | yes |
| `isolated` | absent | no | **no** | yes | yes |

VS Code Remote WSL works in both modes because the connection runs the other way:
the Windows client launches `wsl.exe` and talks to the server in `~/.vscode-server` over a pipe.
Inside that window's integrated terminal, `code` resolves to
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
4. **Compares.** If the result matches the current file (ignoring the timestamp in the
   begin marker) it prints "Nothing to do" and exits 0.
5. **Backs up** to `/etc/wsl.conf.bak.<timestamp>`, writes the new file, `chmod 644`,
   and prints a unified diff against the backup.
6. **Reminds** you to `wsl --shutdown`, with extra warnings in `isolated` mode.

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
`touch /mnt/c/x` fails with "Read-only file system". In `isolated` mode `/mnt/c` does not
exist and `which code` in a VS Code integrated terminal still points into `~/.vscode-server`.

---

## Rolling back

```bash
sudo cp /etc/wsl.conf.bak.<timestamp> /etc/wsl.conf
```

then `wsl --shutdown`. Or run the script again with the other `--mode`.

*(End of document)*
