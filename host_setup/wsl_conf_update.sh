#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# wsl_conf_update.sh  –  install or replace the managed block in /etc/wsl.conf
#
# Usage:   sudo ./wsl_conf_update.sh [--mode ro|isolated] [--win-user NAME]
#                                    [--dry-run] [--conf FILE] [--fstab FILE]
#
#   --mode ro         C: (and other drives) mounted read-only under /mnt/,
#                     Windows interop on.                          (default)
#   --mode isolated   no /mnt/<drive>, Windows interop off. Only the VS Code
#                     extensions folder is mounted (read-only, via /etc/fstab)
#                     because Remote WSL bootstraps from it. `code .` only
#                     from a VS Code integrated terminal.
#   --win-user NAME   Windows user whose extensions folder to mount in
#                     isolated mode. Default: the invoking user ($SUDO_USER).
#   --dry-run         print the resulting files to stdout, write nothing.
#   --conf FILE       operate on FILE instead of /etc/wsl.conf (testing).
#   --fstab FILE      operate on FILE instead of /etc/fstab   (testing).
#
# The wsl.conf block is read from wsl_insert-<mode>.conf next to this script
# and written between marker lines. Re-running replaces the block in place, so
# switching modes is just a second run. Sections outside the markers ([boot],
# [user], …) are left untouched. A pre-marker install (banner "Added by
# add-wsl-conf.sh", no end marker) is migrated: that banner and everything
# after it is replaced.
#
# In isolated mode one marked line is added to /etc/fstab and the mount point
# is created; in ro mode that line is removed again.
# -----------------------------------------------------------------------------
set -euo pipefail

info() { printf '\033[0;36m[INFO]\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[ERR]\033[0m   %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,/^# ----.*$/{/^# ----/d;s/^# \{0,1\}//;p}' "$0" | sed -n '2,$p'; }

MODE="ro"
DRY_RUN=0
CONF_FILE="/etc/wsl.conf"
FSTAB_FILE="/etc/fstab"
WIN_USER="${SUDO_USER:-$USER}"

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)       [ $# -ge 2 ] || die "--mode needs a value"; MODE="$2"; shift 2 ;;
    --mode=*)     MODE="${1#--mode=}"; shift ;;
    --win-user)   [ $# -ge 2 ] || die "--win-user needs a value"; WIN_USER="$2"; shift 2 ;;
    --win-user=*) WIN_USER="${1#--win-user=}"; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --conf)       [ $# -ge 2 ] || die "--conf needs a value"; CONF_FILE="$2"; shift 2 ;;
    --conf=*)     CONF_FILE="${1#--conf=}"; shift ;;
    --fstab)      [ $# -ge 2 ] || die "--fstab needs a value"; FSTAB_FILE="$2"; shift 2 ;;
    --fstab=*)    FSTAB_FILE="${1#--fstab=}"; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "unknown argument: $1 (try --help)" ;;
  esac
done

case "$MODE" in
  ro|isolated) ;;
  *) die "--mode must be 'ro' or 'isolated' (got '$MODE')" ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSERT_FILE="${SCRIPT_DIR}/wsl_insert-${MODE}.conf"
[ -r "$INSERT_FILE" ] || die "cannot read insert file: $INSERT_FILE"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_FILE="${CONF_FILE}.bak.${TIMESTAMP}"
FSTAB_BACKUP="${FSTAB_FILE}.bak.${TIMESTAMP}"

# Marker lines. The begin line carries the mode so a later run can report what
# is currently installed. Keep these stable: the awk below matches on them.
MARK_PREFIX='# >>> windows-ai-sandbox wsl.conf'
BEGIN_LINE="${MARK_PREFIX} (mode=${MODE}, ${TIMESTAMP}) >>>"
END_LINE='# <<< windows-ai-sandbox wsl.conf <<<'
LEGACY_BANNER='# --- Added by add-wsl-conf.sh'

# fstab entry for isolated mode: the VS Code extensions folder, read-only.
# Remote WSL runs $VSCODE_WSL_EXT_LOCATION/scripts/wslServer.sh out of it, and
# WSL's path translation only succeeds for paths under a drvfs mount. Mounting
# the parent "extensions" folder (not the versioned extension dir) survives
# extension updates. Verified 2026-09-15 on Windows build 26200.
FSTAB_TAG='# windows-ai-sandbox: vscode extensions (isolated mode)'
EXT_WIN_PATH="C:\\Users\\${WIN_USER}\\.vscode\\extensions"
EXT_MOUNT="/mnt/c/Users/${WIN_USER}/.vscode/extensions"
EXT_OPTS="ro,uid=$(id -u "${SUDO_USER:-$USER}"),gid=$(id -g "${SUDO_USER:-$USER}"),umask=22,fmask=11"
# fstab unescapes only \ooo octal sequences; the backslashes here are followed
# by letters or '.', so they pass through literally.
FSTAB_ENTRY="${EXT_WIN_PATH} ${EXT_MOUNT} drvfs ${EXT_OPTS} 0 0"
# Written as two lines: the tag comment, then the entry. Stripping removes both.

# -- write permission check (skipped for --dry-run) ---------------------------
writable_or_die() {
  local f="$1"
  if [ -e "$f" ]; then
    [ -w "$f" ] || die "$f is not writable — run with sudo"
  else
    [ -w "$(dirname "$f")" ] || die "$(dirname "$f") is not writable — run with sudo"
  fi
}
if [ "$DRY_RUN" -eq 0 ]; then
  writable_or_die "$CONF_FILE"
  writable_or_die "$FSTAB_FILE"
fi

# -- wsl.conf: read current ----------------------------------------------------
existing=""
if [ -f "$CONF_FILE" ]; then
  existing="$(<"$CONF_FILE")"
fi

current_mode="$(printf '%s\n' "$existing" | sed -n "s/^${MARK_PREFIX//./\\.} (mode=\([a-z]*\),.*/\1/p" | head -n1)"
legacy_present=0
printf '%s\n' "$existing" | grep -Fq "$LEGACY_BANNER" && legacy_present=1

if [ -n "$current_mode" ]; then
  info "installed block: mode=${current_mode}"
elif [ "$legacy_present" -eq 1 ]; then
  info "installed block: pre-marker install (will be migrated)"
else
  info "installed block: none"
fi

# -- wsl.conf: strip the managed block (marked or legacy) ----------------------
# Marked block: drop from begin marker through end marker.
# Legacy block: drop from the legacy banner to end of file (that is exactly what
# the old script appended, and it never wrote anything after it).
stripped="$(printf '%s\n' "$existing" | awk \
  -v begin="$MARK_PREFIX" -v end="$END_LINE" -v legacy="$LEGACY_BANNER" '
  index($0, begin) == 1  { skip = 1; next }
  skip && $0 == end      { skip = 0; next }
  skip                   { next }
  index($0, legacy) == 1 { exit }
  { print }
')"

# Refuse to create duplicate sections: WSL does not define which copy wins.
for section in automount network interop; do
  if printf '%s\n' "$stripped" | grep -Eq "^\[${section}\]"; then
    die "$CONF_FILE has an unmanaged [${section}] section outside the marker block. Remove or merge it by hand, then re-run."
  fi
done

# Trim trailing blank lines so the block is separated by exactly one.
stripped="$(printf '%s\n' "$stripped" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"

# -- wsl.conf: compose ----------------------------------------------------------
block="$(<"$INSERT_FILE")"
if [ -n "$stripped" ]; then
  new_conf="$(printf '%s\n\n%s\n%s\n%s\n' "$stripped" "$BEGIN_LINE" "$block" "$END_LINE")"
else
  new_conf="$(printf '%s\n%s\n%s\n' "$BEGIN_LINE" "$block" "$END_LINE")"
fi

# -- fstab: compose --------------------------------------------------------------
existing_fstab=""
if [ -f "$FSTAB_FILE" ]; then
  existing_fstab="$(<"$FSTAB_FILE")"
fi
# Drop the tag line and the entry right after it, keep everything else.
new_fstab="$(printf '%s\n' "$existing_fstab" | awk -v tag="$FSTAB_TAG" '
  $0 == tag { getline; next }
  { print }
' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
if [ "$MODE" = "isolated" ]; then
  if [ -n "$new_fstab" ]; then
    new_fstab="$(printf '%s\n%s\n%s\n' "$new_fstab" "$FSTAB_TAG" "$FSTAB_ENTRY")"
  else
    new_fstab="$(printf '%s\n%s\n' "$FSTAB_TAG" "$FSTAB_ENTRY")"
  fi
fi

# -- unchanged? (ignore the timestamp in the begin marker) ---------------------
norm() { sed "s/^\(${MARK_PREFIX//./\\.} (mode=[a-z]*\), [0-9-]*) >>>/\1) >>>/"; }
conf_changed=1
fstab_changed=1
[ "$(printf '%s\n' "$existing" | norm)" = "$(printf '%s\n' "$new_conf" | norm)" ] && conf_changed=0
[ "$(printf '%s\n' "$existing_fstab")" = "$(printf '%s\n' "$new_fstab")" ] && fstab_changed=0
mountpoint_missing=0
[ "$MODE" = "isolated" ] && [ ! -d "$EXT_MOUNT" ] && mountpoint_missing=1

if [ "$conf_changed" -eq 0 ] && [ "$fstab_changed" -eq 0 ] && [ "$mountpoint_missing" -eq 0 ]; then
  info "$CONF_FILE and $FSTAB_FILE already match mode=${MODE}. Nothing to do."
  exit 0
fi

# -- isolated: sanity-check the Windows extensions folder when we can see it --
if [ "$MODE" = "isolated" ]; then
  if [ -d "$EXT_MOUNT" ] && [ -n "$(ls -A "$EXT_MOUNT" 2>/dev/null)" ]; then
    info "extensions folder visible now: $EXT_MOUNT"
  elif [ -d "/mnt/c/Users" ]; then
    die "/mnt/c is mounted but $EXT_MOUNT is missing or empty. Wrong --win-user? (see: ls /mnt/c/Users)"
  else
    warn "cannot verify $EXT_WIN_PATH from here (no /mnt/c). Check --win-user is your Windows user name."
  fi
fi

# -- dry run ------------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  info "dry run — resulting $CONF_FILE would be:"
  echo "------------------------------------------------------------------------"
  printf '%s\n' "$new_conf"
  echo "------------------------------------------------------------------------"
  info "dry run — resulting $FSTAB_FILE would be:"
  echo "------------------------------------------------------------------------"
  printf '%s\n' "$new_fstab"
  echo "------------------------------------------------------------------------"
  [ "$mountpoint_missing" -eq 1 ] && info "dry run — would create mount point $EXT_MOUNT"
  exit 0
fi

# -- write --------------------------------------------------------------------
if [ "$conf_changed" -eq 1 ]; then
  if [ -f "$CONF_FILE" ]; then
    info "backing up $CONF_FILE -> $BACKUP_FILE"
    cp -p "$CONF_FILE" "$BACKUP_FILE"
  fi
  printf '%s\n' "$new_conf" > "$CONF_FILE"
  chmod 644 "$CONF_FILE"
fi

if [ "$fstab_changed" -eq 1 ]; then
  if [ -f "$FSTAB_FILE" ]; then
    info "backing up $FSTAB_FILE -> $FSTAB_BACKUP"
    cp -p "$FSTAB_FILE" "$FSTAB_BACKUP"
  fi
  printf '%s\n' "$new_fstab" > "$FSTAB_FILE"
  chmod 644 "$FSTAB_FILE"
fi

if [ "$mountpoint_missing" -eq 1 ]; then
  info "creating mount point $EXT_MOUNT"
  mkdir -p "$EXT_MOUNT"
fi

if [ -n "$current_mode" ] && [ "$current_mode" != "$MODE" ]; then
  info "switched mode ${current_mode} -> ${MODE}"
elif [ "$legacy_present" -eq 1 ]; then
  info "migrated pre-marker install -> mode=${MODE}"
fi
info "$CONF_FILE updated (mode=${MODE})."

if command -v diff >/dev/null 2>&1; then
  if [ "$conf_changed" -eq 1 ] && [ -f "$BACKUP_FILE" ]; then
    echo; diff -u "$BACKUP_FILE" "$CONF_FILE" || true
  fi
  if [ "$fstab_changed" -eq 1 ] && [ -f "$FSTAB_BACKUP" ]; then
    echo; diff -u "$FSTAB_BACKUP" "$FSTAB_FILE" || true
  fi
  echo
fi

warn "restart WSL to apply:  wsl --shutdown   (from PowerShell or CMD), wait ~8s, reopen"
if [ "$MODE" = "isolated" ]; then
  warn "isolated mode: only $EXT_MOUNT is mounted from C:; no Windows .exe runs from Linux."
  warn "open repos from a VS Code window connected to WSL; 'code .' works only in its integrated terminal."
  warn "if VS Code fails to connect, run this script with --mode ro from a Windows Terminal Ubuntu tab, then wsl --shutdown."
fi
