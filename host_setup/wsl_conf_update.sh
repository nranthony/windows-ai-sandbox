#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# wsl_conf_update.sh  –  install or replace the managed block in /etc/wsl.conf
#
# Usage:   sudo ./wsl_conf_update.sh [--mode ro|isolated] [--dry-run] [--conf FILE]
#
#   --mode ro         C: (and other drives) mounted read-only under /mnt/,
#                     Windows interop on.                          (default)
#   --mode isolated   no /mnt/<drive> at all, Windows interop off.
#                     VS Code Remote WSL keeps working; `code .` only from a
#                     VS Code integrated terminal.
#   --dry-run         print the resulting file to stdout, write nothing.
#   --conf FILE       operate on FILE instead of /etc/wsl.conf (testing).
#
# The block is read from wsl_insert-<mode>.conf next to this script and written
# between marker lines. Re-running replaces the block in place, so switching
# modes is just a second run. Sections outside the markers ([boot], [user], …)
# are left untouched. A pre-marker install (banner "Added by add-wsl-conf.sh",
# no end marker) is migrated: that banner and everything after it is replaced.
# -----------------------------------------------------------------------------
set -euo pipefail

info() { printf '\033[0;36m[INFO]\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[ERR]\033[0m   %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,/^# ----.*$/{/^# ----/d;s/^# \{0,1\}//;p}' "$0" | sed -n '2,$p'; }

MODE="ro"
DRY_RUN=0
CONF_FILE="/etc/wsl.conf"

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)     [ $# -ge 2 ] || die "--mode needs a value"; MODE="$2"; shift 2 ;;
    --mode=*)   MODE="${1#--mode=}"; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --conf)     [ $# -ge 2 ] || die "--conf needs a value"; CONF_FILE="$2"; shift 2 ;;
    --conf=*)   CONF_FILE="${1#--conf=}"; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "unknown argument: $1 (try --help)" ;;
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

# Marker lines. The begin line carries the mode so a later run can report what
# is currently installed. Keep these stable: the awk below matches on them.
MARK_PREFIX='# >>> windows-ai-sandbox wsl.conf'
BEGIN_LINE="${MARK_PREFIX} (mode=${MODE}, ${TIMESTAMP}) >>>"
END_LINE='# <<< windows-ai-sandbox wsl.conf <<<'
LEGACY_BANNER='# --- Added by add-wsl-conf.sh'

# -- write permission check (skipped for --dry-run) ---------------------------
if [ "$DRY_RUN" -eq 0 ]; then
  if [ -e "$CONF_FILE" ]; then
    [ -w "$CONF_FILE" ] || die "$CONF_FILE is not writable — run with sudo"
  else
    [ -w "$(dirname "$CONF_FILE")" ] || die "$(dirname "$CONF_FILE") is not writable — run with sudo"
  fi
fi

# -- read current file ---------------------------------------------------------
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

# -- strip the managed block (marked or legacy) --------------------------------
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

# -- compose ------------------------------------------------------------------
block="$(<"$INSERT_FILE")"
if [ -n "$stripped" ]; then
  new_conf="$(printf '%s\n\n%s\n%s\n%s\n' "$stripped" "$BEGIN_LINE" "$block" "$END_LINE")"
else
  new_conf="$(printf '%s\n%s\n%s\n' "$BEGIN_LINE" "$block" "$END_LINE")"
fi

# -- unchanged? (ignore the timestamp in the begin marker) ---------------------
norm() { sed "s/^\(${MARK_PREFIX//./\\.} (mode=[a-z]*\), [0-9-]*) >>>/\1) >>>/"; }
if [ "$(printf '%s\n' "$existing" | norm)" = "$(printf '%s\n' "$new_conf" | norm)" ]; then
  info "$CONF_FILE already has the mode=${MODE} block. Nothing to do."
  exit 0
fi

# -- dry run ------------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  info "dry run — resulting $CONF_FILE would be:"
  echo "------------------------------------------------------------------------"
  printf '%s\n' "$new_conf"
  echo "------------------------------------------------------------------------"
  exit 0
fi

# -- write --------------------------------------------------------------------
if [ -f "$CONF_FILE" ]; then
  info "backing up $CONF_FILE -> $BACKUP_FILE"
  cp -p "$CONF_FILE" "$BACKUP_FILE"
fi

printf '%s\n' "$new_conf" > "$CONF_FILE"
chmod 644 "$CONF_FILE"

if [ -n "$current_mode" ] && [ "$current_mode" != "$MODE" ]; then
  info "switched mode ${current_mode} -> ${MODE}"
elif [ "$legacy_present" -eq 1 ]; then
  info "migrated pre-marker install -> mode=${MODE}"
fi
info "$CONF_FILE updated (mode=${MODE})."

if [ -f "$BACKUP_FILE" ] && command -v diff >/dev/null 2>&1; then
  echo
  diff -u "$BACKUP_FILE" "$CONF_FILE" || true
  echo
fi

warn "restart WSL to apply:  wsl --shutdown   (from PowerShell or CMD), wait ~8s, reopen"
if [ "$MODE" = "isolated" ]; then
  warn "isolated mode: /mnt/c is gone and no Windows .exe runs from Linux."
  warn "open repos from a VS Code window connected to WSL; 'code .' works only in its integrated terminal."
fi
