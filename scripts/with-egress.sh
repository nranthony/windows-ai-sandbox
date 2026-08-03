#!/usr/bin/env bash
# =============================================================================
# with-egress.sh — temporarily widen the egress proxy allowlist for one command
# =============================================================================
# Usage:
#   scripts/with-egress.sh <profile> [--with pypi[,npm,git,...]] -- <cmd>
#
# Default --with: pypi
# Section tags match `[<tag>]` in proxy/allowed_domains.txt — typical
# planning-mode tags: pypi, npm, git, playwright-install. <cmd> runs inside
# the profile's agent container as `bash -lc <cmd>`.
#
# The allowlist file is backed up before opening and *restored verbatim* on
# exit (success, failure, Ctrl-C). Squid is hot-reloaded on both transitions.
# This is the scripted version of the manual "uncomment / restart squid /
# install / re-comment / restart squid" loop.
#
# INSTRUMENTED (phase 3, T18-T22). Because ADR-0003 makes registries unreachable
# by default, this script is the ONLY route by which a dependency can enter a
# profile. That makes it the one place worth measuring: a bracket here is a
# record, not a sample. Each run:
#
#   T18  pre-flight — explicit package names in <cmd> are checked against OSV
#        before the window opens. A live MAL- record REFUSES to open it.
#   T19  bracket    — epoch open/close, plus a before/after snapshot of lockfile
#        hashes and installed-module listings under /workspace.
#   T20  egress     — distinct hosts reached during the bracket, split into
#        permitted and DENIED, read from the proxy's own access.log.
#   T21  filesystem — module directory entries added/removed across the window.
#   T22  persist    — one JSON line per window appended to
#        ~/.ai-sandbox/profiles/<profile>/audit/depgate.jsonl (host side, so it
#        survives `docker rm`). Read it back with `profile.sh <p> deps --history`.
#
# Requires python3 on the HOST (for the OSV check and JSON emission). Failure to
# write the audit line warns; it never fails an otherwise-successful install.
#
# windows-ai-sandbox note: most [pypi]/[npm]/[git]/etc. sections are in the
# PROJECT-PERSISTENT block (uncommented by default), unlike macolima where
# they live in PLANNING-MODE and are commented. open_section() is idempotent
# on already-open sections — calling it with --with pypi when [pypi] is
# already uncommented is a safe no-op.
#
# Examples:
#   scripts/with-egress.sh alpha -- \
#     'cd /workspace/foo && uv pip install -e ".[dev]" --python .venv/bin/python'
#
#   scripts/with-egress.sh alpha --with playwright-install -- \
#     'cd /workspace/foo && playwright install chromium'
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOWLIST="$REPO_ROOT/proxy/allowed_domains.txt"
COMPOSE_FILE="$REPO_ROOT/docker-compose.yml"
PROFILES_ROOT="$HOME/.ai-sandbox/profiles"

profile=""
sections="pypi"
cmd=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with)
      sections="${2:?--with requires a value}"
      shift 2
      ;;
    --)
      shift
      cmd=("$@")
      break
      ;;
    -h|--help)
      sed -n '2,34p' "$0"
      exit 0
      ;;
    -*)
      echo "Unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [[ -z "$profile" ]]; then
        profile="$1"
        shift
      else
        echo "Unexpected positional arg: $1 (did you forget the -- before the command?)" >&2
        exit 2
      fi
      ;;
  esac
done

[[ -n "$profile" ]] || { echo "Missing <profile>. Usage: scripts/with-egress.sh <profile> [--with list] -- <cmd>" >&2; exit 2; }
[[ ${#cmd[@]} -gt 0 ]] || { echo "Missing -- <cmd>. Usage: scripts/with-egress.sh <profile> [--with list] -- <cmd>" >&2; exit 2; }

# python3 is a hard requirement, not an optional enhancement: it runs the T18
# pre-flight and emits the T22 audit record. Both are part of what this script
# now IS. Degrading silently to an uninstrumented window would leave the audit
# log with gaps that look identical to "no installs happened".
command -v python3 >/dev/null 2>&1 \
  || { echo "python3 not found on the host — required for the pre-flight check and audit log" >&2; exit 2; }

IFS=',' read -ra SECTIONS <<< "$sections"

# Validate every requested section exists somewhere in the file (commented or not).
# Anchor on the trailing `[tag] ---` which is unique to section headers.
for s in "${SECTIONS[@]}"; do
  if ! grep -qE -e "--- .* \[$s\] ---" "$ALLOWLIST"; then
    {
      echo "No section [$s] in $ALLOWLIST. Known section tags:"
      grep -oE -e '--- .* \[[a-z-]+\] ---' "$ALLOWLIST" | grep -oE -e '\[[a-z-]+\]' | sort -u
    } >&2
    exit 2
  fi
done

reload_proxy() {
  # Zero-downtime config reload via squid -k reconfigure. Squid validates
  # the new config before applying — if there's a syntax error it logs to
  # cache.log and keeps running on the old config (safer than a hard
  # restart that would crash-loop on bad config). Falls back to a
  # compose-level restart only if exec fails.
  #
  # `reconfigure` IS CORRECT HERE, and only because of how this script writes.
  # open_section uses `cat tmp > $ALLOWLIST` and cleanup uses
  # `cp backup $ALLOWLIST` — both truncate in place and PRESERVE the inode the
  # running proxy is bind-mounted to, so squid re-reads the bytes we just wrote.
  #
  # Do NOT copy this pattern to a call site that edits the allowlist with an
  # atomic replace (`vim`, `sed -i`, `git checkout`, mktemp+mv). Those give the
  # host file a NEW inode; the container stays bound to the old one, and
  # reconfigure then exits 0 having applied nothing at all — a silent no-op, not
  # an error the fallback below can catch. Such call sites must use
  # `docker restart egress-proxy-<profile>`, which re-resolves the mount.
  # Measured 2026-07-31; see docs/squid-internals.md.
  #
  # (An earlier claim that reconfigure KILLS the proxy — squid as foreground PID
  # taking SIGHUP as Hangup, exit 129 — is refuted. squid is a child of
  # entrypoint.sh, handles SIGHUP as a reconfigure, and the container survives.
  # This function was never broken by that.)
  if docker exec "egress-proxy-$profile" squid -k reconfigure >/dev/null 2>&1; then
    return 0
  fi
  echo "WARN: squid -k reconfigure failed for egress-proxy-$profile, falling back to compose restart" >&2
  PROFILE="$profile" COMPOSE_PROJECT_NAME="ai-sandbox-$profile" \
    docker compose -f "$COMPOSE_FILE" restart egress-proxy >/dev/null
}

# Section bounds: header line until the next section header or a blank line.
# Header gets normalized from `# # ---` to `# ---`; domain lines starting
# with `# ` get one `# ` stripped. Idempotent on already-open sections.
open_section() {
  local sec="$1"
  awk -v sec="$sec" '
    BEGIN { inside = 0 }
    /--- .* \[[a-z-]+\] ---/ {
      if (match($0, /\[[a-z-]+\]/)) {
        tag = substr($0, RSTART+1, RLENGTH-2)
        if (tag == sec) {
          inside = 1
          sub(/^# # /, "# ")
          print
          next
        } else if (inside) {
          inside = 0
        }
      }
    }
    /^[[:space:]]*$/ { if (inside) inside = 0; print; next }
    inside && /^# / { sub(/^# /, ""); print; next }
    { print }
  ' "$ALLOWLIST" > "$ALLOWLIST.tmp" && cat "$ALLOWLIST.tmp" > "$ALLOWLIST" && rm -f "$ALLOWLIST.tmp"
}

# =============================================================================
# Instrumentation (phase 3, T18-T22)
# =============================================================================
AGENT="ai-sandbox-$profile"
PROXY="egress-proxy-$profile"
# Container-side allowlist path. MUST agree with the mount target in
# docker-compose.yml, the acl in proxy/squid.conf, and the same constant in
# scripts/profile.sh and dashboard/src/lib/docker_client.py.
# `bash scripts/with-egress.test.sh` locks all five together.
PROXY_ALLOWLIST="/etc/squid/host/allowed_domains.txt"
DEPAUDIT="$REPO_ROOT/scripts/depaudit.py"
AUDIT_DIR="$PROFILES_ROOT/$profile/audit"
AUDIT_LOG="$AUDIT_DIR/depgate.jsonl"

# T18 — extract explicitly-named packages from the command.
#
# Deliberately only EXPLICIT names. `npm ci`, `pnpm install --frozen-lockfile`
# and `uv sync` install from a lockfile, whose contents were already gated at
# resolution time by the age window (Gate 2) — there is no name here to check
# that was not checked when it was written. Reporting them would be noise, and
# noise is what got the G10 check rewritten.
extract_specs() {
  printf '%s\n' "$*" | tr ';|&' '\n' | awk '
    # `name` and `i` MUST be declared as extra parameters. awk has no other way
    # to make a function variable local, and `i` is the caller`s loop counter —
    # assigning to a global `i` here rewinds the outer for-loop and the whole
    # program spins forever. The extra spaces before them are the convention
    # that marks them as locals; awk itself just sees unpassed arguments.
    function emit(eco, tok,    name, i) {
      if (tok ~ /^-/) return                       # flag
      if (tok ~ /^[.\/]/) return                   # path / local install
      if (tok ~ /^\$/ || tok ~ /[*?]/) return      # var or glob — cannot resolve statically
      # strip a version specifier; npm scopes start with @ so only split a LATER one
      name = tok
      sub(/(==|>=|<=|~=|!=|[<>=~^]).*$/, "", name)
      if (substr(name, 1, 1) == "@") {
        i = index(substr(name, 2), "@")
        if (i > 0) name = substr(name, 1, i)
      } else {
        i = index(name, "@")
        if (i > 0) name = substr(name, 1, i - 1)
      }
      gsub(/^["'"'"']|["'"'"']$/, "", name)
      if (name == "") return
      if (name ~ /^[A-Za-z0-9@._\/-]+$/) print eco, name
    }
    {
      eco = ""; start = 0
      for (i = 1; i <= NF; i++) {
        if ($i == "npm" || $i == "pnpm" || $i == "yarn" || $i == "bun") {
          v = $(i+1)
          if (v == "add" || v == "i" || v == "install") {
            # bare `npm install` / `pnpm install` with no names = lockfile install
            eco = "npm"; start = i + 2
          }
        } else if ($i == "pip" || $i == "pip3") {
          if ($(i+1) == "install") { eco = "pypi"; start = i + 2 }
        } else if ($i == "uv") {
          if ($(i+1) == "add") { eco = "pypi"; start = i + 2 }
          else if ($(i+1) == "pip" && $(i+2) == "install") { eco = "pypi"; start = i + 3 }
        } else if ($i == "poetry") {
          if ($(i+1) == "add") { eco = "pypi"; start = i + 2 }
        } else if ($i == "cargo") {
          if ($(i+1) == "add") { eco = "cargo"; start = i + 2 }
        }
        if (start > 0) {
          for (j = start; j <= NF; j++) emit(eco, $j)
          eco = ""; start = 0
        }
      }
    }
  ' | sort -u
}

# T18 — refuse the window on a live malicious-package record.
#
# Fails OPEN on UNKNOWN (offline, API error, rate limit). That is deliberate and
# is the same argument depaudit itself makes: a clean OSV result means "nothing
# known yet", never "safe", so the check is confidence and not a boundary. Since
# this script is the only install route, hard-failing it on a network hiccup
# would break all installs to defend against nothing.
PREFLIGHT_JSON="[]"
preflight() {
  local specs; specs="$(extract_specs "${cmd[*]}")"
  [[ -n "$specs" ]] || { echo "→ pre-flight: no explicitly-named packages in the command (lockfile install?)" >&2; return 0; }

  local blocked=0 rows=""
  while read -r eco name; do
    [[ -n "$name" ]] || continue
    local out verdict detail
    out="$(python3 "$DEPAUDIT" pkg "$eco" "$name" --format json 2>/dev/null)" || out=""
    if [[ -z "$out" ]]; then
      verdict="UNKNOWN"; detail="depaudit produced no result"
    else
      verdict="$(printf '%s' "$out" | python3 -c 'import sys,json;r=json.load(sys.stdin)["results"];print(r[0]["verdict"] if r else "UNKNOWN")' 2>/dev/null || echo UNKNOWN)"
      detail="$(printf '%s' "$out" | python3 -c 'import sys,json;r=json.load(sys.stdin)["results"];print(r[0].get("detail","") if r else "")' 2>/dev/null || echo '')"
    fi
    rows="${rows}${eco}"$'\t'"${name}"$'\t'"${verdict}"$'\t'"${detail}"$'\n'
    case "$verdict" in
      BLOCK)   echo "  ✗ BLOCK  $eco/$name — $detail" >&2; blocked=1 ;;
      INFO)    echo "  ! INFO   $eco/$name — $detail" >&2 ;;
      UNKNOWN) echo "  ? UNKNOWN $eco/$name — $detail (proceeding; the age gate still applies)" >&2 ;;
      *)       echo "  ✓ $verdict $eco/$name" >&2 ;;
    esac
  done <<< "$specs"

  PREFLIGHT_JSON="$(printf '%s' "$rows" | python3 -c '
import sys, json
out = []
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    while len(parts) < 4:
        parts.append("")
    out.append({"eco": parts[0], "name": parts[1], "verdict": parts[2], "detail": parts[3]})
print(json.dumps(out))
' 2>/dev/null || echo '[]')"

  if (( blocked )); then
    echo "REFUSING to open the egress window: a live OSV malicious-package record names a package in this command." >&2
    echo "If you believe the record is wrong, verify it at https://osv.dev and install with an explicit manual allowlist edit." >&2
    return 1
  fi
  return 0
}

# Confirm the proxy can READ the widened allowlist at the expected path.
#
# BE CLEAR ABOUT WHAT THIS DOES AND DOES NOT PROVE. It compares file contents,
# so it proves the mount is healthy and the path is right. It does NOT prove
# squid has re-parsed the list — squid reads it into memory at start, so
# enforcement follows the reload, not the file. Enforcement is inferred from
# reload_proxy returning 0, and that inference is now sound in a way it was not
# before: under the directory mount there is no longer a mode in which
# `squid -k reconfigure` silently re-reads a stale copy and reports success.
#
# Under the previous single-FILE bind mount this function was load-bearing for a
# different reason — it was the only thing catching a container pinned to a
# replaced inode (git checkout/merge/pull/stash, editor atomic saves, sed -i).
# That class is gone: docker-compose.yml now mounts ./proxy as a DIRECTORY, so
# the path resolves on every open() and the container always sees current bytes.
#
# What it still earns its place for:
#   - a botched mount target (this path and compose disagreeing)
#   - a profile that predates the directory mount and has not been recreated
# Both are real during rollout, and both otherwise present as an install failing
# with an error that names nothing — which is exactly how the 2026-08-03
# incident presented.
#
# The definitive check would be an egress probe against a just-opened host.
# Deliberately not built: it needs a section -> canonical-host mapping, and with
# the silent-no-op mode removed the marginal value is small. Revisit if a window
# is ever observed opening without taking effect.
assert_allowlist_visible() {
  local host_doms ctr_doms
  host_doms="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$ALLOWLIST" | sort)"
  ctr_doms="$(docker exec -u proxy "$PROXY" \
    grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$PROXY_ALLOWLIST" 2>/dev/null | sort)" || return 1
  [[ "$host_doms" == "$ctr_doms" ]]
}

require_allowlist_visible() {
  assert_allowlist_visible && return 0
  echo "WARN: $PROXY is not serving this allowlist at $PROXY_ALLOWLIST." >&2
  echo "      Most likely this profile predates the directory mount and still has the" >&2
  echo "      old single-file bind mount. Restarting to re-resolve; if that does not" >&2
  echo "      fix it, recreate the profile with 'scripts/profile.sh $profile up'." >&2
  docker restart "$PROXY" >/dev/null 2>&1 || { echo "ERROR: could not restart $PROXY" >&2; return 1; }
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    assert_allowlist_visible && { echo "→ $PROXY restarted and serving the widened allowlist" >&2; return 0; }
    sleep 1
  done
  echo "ERROR: $PROXY still cannot serve this allowlist after a restart." >&2
  echo "       Refusing to run the command: the window may not be open, and an audit" >&2
  echo "       record for an install that could not reach a registry is worse than none." >&2
  echo "       Fix: scripts/profile.sh $profile up   (recreates with the directory mount)" >&2
  return 1
}

# T19/T21 — one line per lockfile hash and per installed module entry.
# node_modules and site-packages are pruned so nested copies are not walked;
# their TOP-LEVEL entries are what a new package shows up in.
snapshot() {
  docker exec "$AGENT" bash -lc '
    find /workspace -maxdepth 6 -name .git -prune -o \
      -type d \( -name node_modules -o -name site-packages \) -prune -print 2>/dev/null |
      while IFS= read -r d; do
        ls -1 "$d" 2>/dev/null | sed "s|^|M ${d#/workspace/}/|"
      done
    find /workspace -maxdepth 6 \( -name node_modules -o -name .git -o -name .venv \) -prune -o \
      -type f \( -name pnpm-lock.yaml -o -name package-lock.json -o -name yarn.lock \
                 -o -name bun.lock -o -name bun.lockb -o -name uv.lock -o -name poetry.lock \
                 -o -name Pipfile.lock -o -name "requirements*.txt" \) -print 2>/dev/null |
      while IFS= read -r f; do
        printf "L %s %s\n" "$(sha256sum "$f" 2>/dev/null | cut -d" " -f1)" "${f#/workspace/}"
      done
  ' 2>/dev/null | sort
}

# T20 — distinct hosts reached inside the bracket.
#
# `-u proxy` is LOAD-BEARING: the container is cap_drop:ALL + cap_add SETGID/SETUID
# (CapEff 0xc0), so UID 0 has no CAP_DAC_OVERRIDE against the 0640 proxy:proxy
# log and `docker exec` as root reads nothing. Measured 2026-07-31.
#
# Filtering by TIMESTAMP rather than a byte offset survives a proxy restart
# mid-window, which reload_proxy can cause.
egress_hosts() {
  local from="$1" to="$2"
  # `$1 < e + 1`, NOT `$1 <= e`. Squid logs epoch.MILLISECONDS while `date +%s`
  # truncates to the second, so TS_CLOSE=...808 means "closed at some point
  # during second 808" — and a request logged at ...808.063 is inside the window
  # but fails `<= 808`. MEASURED 2026-08-03: a successful `uv pip install six`
  # reached pypi.org at .063 of the closing second and the audit record claimed
  # zero egress. Under-reporting is the worst failure mode an audit log has: it
  # is indistinguishable from a clean run.
  docker exec -u proxy "$PROXY" awk -v s="$from" -v e="$to" '
    $1 >= s && $1 < e + 1 {
      url = $7
      sub(/^[a-z]+:\/\//, "", url)     # strip scheme on non-CONNECT lines
      sub(/\/.*$/, "", url)            # strip path
      sub(/:[0-9]+$/, "", url)         # strip port
      if (url == "" || url == "-") next
      split($4, st, "/")
      print (st[1] ~ /DENIED/ ? "denied" : "allowed"), url
    }
  ' /var/log/squid/access.log 2>/dev/null | sort -u
}

# --- concurrency + drift guard --------------------------------------------
# Two independent concerns:
#   1. Concurrent invocations for the same profile would race on the shared
#      allowlist file. flock on a per-profile lock file serialises.
#   2. SIGKILL (or sudden host shutdown / container kill) bypasses the EXIT
#      trap, leaving the allowlist widened on disk. The sentinel file flags
#      drift; `scripts/profile.sh <p> verify` (Tier 1) could surface it.
LOCKDIR="/tmp/with-egress.locks"
mkdir -p "$LOCKDIR" 2>/dev/null || true
LOCKFILE="$LOCKDIR/$profile.lock"
mkdir -p "$PROFILES_ROOT" 2>/dev/null || true
SENTINEL="$PROFILES_ROOT/.egress-widened-$profile"

# Acquire exclusive lock (non-blocking).
exec 200>"$LOCKFILE"
if ! flock -n 200; then
  echo "Another with-egress.sh is already running for profile '$profile' (lock: $LOCKFILE)." >&2
  echo "If that's wrong (stale lock from a SIGKILL'd run), remove the lock and retry:" >&2
  echo "  rm '$LOCKFILE'" >&2
  exit 3
fi

backup="$(mktemp -t with-egress.XXXXXX)"
cp "$ALLOWLIST" "$backup"

snap_before="$(mktemp -t with-egress-snap.XXXXXX)"
snap_after="$(mktemp -t with-egress-snap.XXXXXX)"

# Split out of cleanup() so the window can be closed the instant the command
# returns, rather than after the post-window analysis. The analysis is several
# `docker exec` round-trips; holding a widened allowlist open across them is
# exposure that buys nothing.
WINDOW_OPEN=""
close_window() {
  [[ -n "$WINDOW_OPEN" ]] || return 0
  WINDOW_OPEN=""
  echo "→ restoring allowlist + reloading proxy" >&2
  cp "$backup" "$ALLOWLIST"
  rm -f "$SENTINEL"
  reload_proxy || echo "WARN: proxy reload on cleanup failed" >&2
}

cleanup() {
  local rc=$?
  close_window
  rm -f "$backup" "$snap_before" "$snap_after"
  # flock is released when fd 200 closes on shell exit.
  exit "$rc"
}
trap cleanup EXIT INT TERM

# T18 — pre-flight BEFORE the window opens. A refusal here means nothing was
# ever reachable, which is the whole point of checking at this position rather
# than after the install.
echo "→ pre-flight (OSV malicious-package check)" >&2
preflight || exit 4

TS_OPEN="$(date +%s)"
snapshot > "$snap_before"

# Drop the drift sentinel BEFORE widening — so if open_section / reload_proxy
# fail and we hit the trap mid-widen, the sentinel still exists to flag drift.
{
  printf 'profile=%s\nsections=%s\npid=%s\nstarted=%s\ncmd=%s\n' \
    "$profile" "$sections" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${cmd[*]}"
} > "$SENTINEL"
WINDOW_OPEN=1

echo "→ opening egress sections: ${SECTIONS[*]}" >&2
for s in "${SECTIONS[@]}"; do open_section "$s"; done
reload_proxy

# The window is not open until the proxy can serve it. Without this the command
# runs against the OLD allowlist and fails in a way that names nothing.
require_allowlist_visible || exit 5

echo "→ exec $AGENT: ${cmd[*]}" >&2
rc=0
docker exec "$AGENT" bash -lc "${cmd[*]}" || rc=$?

close_window
TS_CLOSE="$(date +%s)"
snapshot > "$snap_after"

# --- T20/T21/T22: what happened inside the bracket -------------------------
# A changed lockfile shows up as a new `L <hash> <path>` line; a changed hash on
# an existing path and a brand-new lockfile are the same signal here.
locks_changed="$(comm -13 "$snap_before" "$snap_after" | awk '$1=="L"{print $3}' | sort -u)"
mods_added="$(comm -13 "$snap_before" "$snap_after" | sed -n 's/^M //p')"
mods_removed="$(comm -23 "$snap_before" "$snap_after" | sed -n 's/^M //p')"

egress_raw="$(egress_hosts "$TS_OPEN" "$TS_CLOSE")"
hosts_allowed="$(printf '%s\n' "$egress_raw" | awk '$1=="allowed"{print $2}')"
hosts_denied="$(printf '%s\n' "$egress_raw" | awk '$1=="denied"{print $2}')"

if [[ -n "$hosts_denied" ]]; then
  echo "→ DENIED during the window (reached for, not allowlisted):" >&2
  printf '     %s\n' $hosts_denied >&2
fi
echo "→ window ${TS_OPEN}..${TS_CLOSE} ($((TS_CLOSE - TS_OPEN))s) · hosts $(printf '%s' "$hosts_allowed" | grep -c . || true) permitted, $(printf '%s' "$hosts_denied" | grep -c . || true) denied · lockfiles changed $(printf '%s' "$locks_changed" | grep -c . || true) · modules +$(printf '%s' "$mods_added" | grep -c . || true)/-$(printf '%s' "$mods_removed" | grep -c . || true)" >&2

mkdir -p "$AUDIT_DIR" 2>/dev/null || true
if WE_TS_OPEN="$TS_OPEN" WE_TS_CLOSE="$TS_CLOSE" WE_PROFILE="$profile" \
   WE_SECTIONS="$sections" WE_CMD="${cmd[*]}" WE_RC="$rc" \
   WE_PREFLIGHT="$PREFLIGHT_JSON" WE_ALLOWED="$hosts_allowed" WE_DENIED="$hosts_denied" \
   WE_LOCKS="$locks_changed" WE_ADDED="$mods_added" WE_REMOVED="$mods_removed" \
   python3 - >> "$AUDIT_LOG" <<'PY'
import os, json

CAP = 50  # per-list cap; the count is always exact and truncation is flagged

def lines(key):
    return [x for x in os.environ.get(key, "").splitlines() if x.strip()]

def capped(key):
    v = lines(key)
    return {"count": len(v), "sample": v[:CAP], "truncated": len(v) > CAP}

try:
    preflight = json.loads(os.environ.get("WE_PREFLIGHT") or "[]")
except json.JSONDecodeError:
    preflight = []

rec = {
    "ts_open":   int(os.environ["WE_TS_OPEN"]),
    "ts_close":  int(os.environ["WE_TS_CLOSE"]),
    "duration_s": int(os.environ["WE_TS_CLOSE"]) - int(os.environ["WE_TS_OPEN"]),
    "profile":   os.environ["WE_PROFILE"],
    "sections":  [s for s in os.environ.get("WE_SECTIONS", "").split(",") if s],
    "cmd":       os.environ.get("WE_CMD", ""),
    "rc":        int(os.environ.get("WE_RC") or 0),
    "preflight": preflight,
    "egress":    {"allowed": lines("WE_ALLOWED"), "denied": lines("WE_DENIED")},
    "lockfiles_changed": lines("WE_LOCKS"),
    "modules_added":     capped("WE_ADDED"),
    "modules_removed":   capped("WE_REMOVED"),
}
print(json.dumps(rec, separators=(",", ":"), sort_keys=True))
PY
then
  echo "→ audit: appended to ${AUDIT_LOG/#$HOME/\~}" >&2
else
  echo "WARN: could not append the audit record to $AUDIT_LOG (the install itself is unaffected)" >&2
fi

exit "$rc"
