#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# wsl_conf_update.sh  –  Update /etc/wsl.conf using the contents of wsl_insert.conf
#
# Usage:   sudo ./wsl_conf_update.sh
# -----------------------------------------------------------------------------
set -euo pipefail

CONF_FILE="/etc/wsl.conf"
BACKUP_DIR="/etc"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_FILE="${BACKUP_DIR}/wsl.conf.bak.${TIMESTAMP}"

# -- where to read the insert block from --------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSERT_FILE="${SCRIPT_DIR}/wsl_insert.conf"
# -----------------------------------------------------------------------------

# 0. Sanity check
if [[ ! -r $INSERT_FILE ]]; then
  echo "❌  Cannot read insert file: $INSERT_FILE" >&2
  exit 1
fi

NEW_CONF="$(<"$INSERT_FILE")"        # read entire file into variable

# 1. If /etc/wsl.conf already contains the block’s first headline, skip
if [[ -f $CONF_FILE ]] && grep -Fq '[automount]' "$CONF_FILE" && \
   grep -Fq '[interop]' "$CONF_FILE"; then
  echo "ℹ️  /etc/wsl.conf already appears to have the desired sections. Exiting."
  exit 0
fi

# 2. Backup current file (even if empty)
if [[ -f $CONF_FILE ]]; then
  echo "🔒 Backing up existing wsl.conf  →  ${BACKUP_FILE}"
  cp -p "$CONF_FILE" "$BACKUP_FILE"
fi

# 3. Write or append the new configuration
if [[ ! -s $CONF_FILE ]]; then
  echo "📝 Creating /etc/wsl.conf"
  printf '%s\n' "$NEW_CONF" > "$CONF_FILE"
else
  echo -e "\n\n# --- Added by add-wsl-conf.sh (${TIMESTAMP}) ---" >> "$CONF_FILE"
  printf '%s\n' "$NEW_CONF" >> "$CONF_FILE"
fi

chmod 644 "$CONF_FILE"
echo "✅  /etc/wsl.conf updated successfully."

echo -e "\n⚠️  Restart WSL to apply changes:\n   wsl --shutdown  (from PowerShell or CMD)"
