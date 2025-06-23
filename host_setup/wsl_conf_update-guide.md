# wsl_conf_update.sh – Annotated Guide  
*Updated: 23 Jun 2025*

This helper script safely merges **`wsl_insert.conf`** into `/etc/wsl.conf`.  
It is designed to be run with **`sudo`** exactly once during install, but you can re‑run it if you ship an updated insert block later.

---

## 1. Safety First  

```bash
set -euo pipefail
```

Standard shell flags to abort on error, undefined variables, or failed pipelines.

---

## 2. Backup Existing Config  

```bash
BACKUP_FILE="/etc/wsl.conf.bak.$(date +%Y%m%d-%H%M%S)"
cp /etc/wsl.conf "$BACKUP_FILE"
```

If a previous config exists it is copied with a timestamp so you can roll back.

---

## 3. Locate `wsl_insert.conf`  

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSERT_FILE="${SCRIPT_DIR}/wsl_insert.conf"
```

This relative lookup means you can run the script from **any** directory; it always finds the insert file next to itself.

---

## 4. Detect Duplicate Blocks  

An `awk`/`grep` search looks for a sentinel line (`[automount]` with `metadata,umask=22,fmask=11`) inside the current `/etc/wsl.conf`.  
If found, the script exits gracefully to avoid duplicate sections.

---

## 5. Append or Create  

* **Empty or missing `/etc/wsl.conf`** – the file is created from scratch.  
* **Existing file** – two newline breaks plus a comment banner are added, then the new block.

```bash
echo -e "\n\n# --- Added by wsl_conf_update.sh (TIMESTAMP) ---" >> /etc/wsl.conf
```

---

## 6. Permissions & Reminder  

`chmod 644 /etc/wsl.conf` sets sane world‑readability but prevents accidental edits by regular users.  
Finally, the script prints:

```
wsl --shutdown
```

because WSL only re‑reads the file on boot.

---

## Re‑Running the Script  

If you later make changes in `wsl_insert.conf`, simply run:

```bash
sudo ./wsl_conf_update.sh
```

The script will again back up the current file and append the new changes after a banner.  
Nothing is ever deleted.

*(End of document)*