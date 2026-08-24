#!/usr/bin/env bash
# =============================================================================
# with-egress.sh — temporarily widen the egress proxy allowlist for one command
# =============================================================================
# Usage:
#   scripts/with-egress.sh <profile> [--with pypi[,npm,git,...]]
#                                    [--allow-fresh "<reason>"] -- <cmd>
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
#   T24  age gate   — UV_EXCLUDE_NEWER is injected into the command's
#        environment at (now - 7 days), giving Python the same relative
#        quarantine npm gets from min-release-age=7. `exclude-newer` takes a
#        TIMESTAMP, not a duration, which is why this could never be an
#        image-wide setting; the install window is the one place that knows the
#        moment it opens and can do the conversion. Suppress it for one window
#        with `--allow-fresh "<reason>"` — the reason is required and lands in
#        the audit record, because an opt-out nobody can see later is not one.
#
# --allow-fresh exists for the legitimately-fresh package: a same-week security
# fix is real, and a gate with no visible escape hatch gets bypassed invisibly
# instead (someone runs the install outside this script). Making the hatch
# loud and recorded is the point.
#
# Requires python3 on the HOST (for the OSV check and JSON emission). Failure to
# write the audit line warns; it never fails an otherwise-successful install.
#
# windows-ai-sandbox note: the gated sections ([pypi]/[npm]/[pytorch]/[apt]/…)
# sit in the PROJECT-PERSISTENT block and are COMMENTED by default, same stance
# as macolima's PLANNING-MODE. An earlier version of this note said they were
# uncommented by default; that stopped being true at fc7c0f0, which commented
# pypi, npm, numerai and kaggle. [git] is the one gated section still open in
# the committed baseline, and that is a recorded decision, not a leftover — the
# reasoning is above its block in proxy/allowed_domains.txt and the audit probe
# defers to it (ACCEPTED_OPEN_TAGS in scripts/audit/probes/proxy.py).
# open_section() is idempotent on already-open sections — calling it with
# --with pypi when [pypi] is already uncommented is a safe no-op.
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
allow_fresh=""
cmd=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with)
      sections="${2:?--with requires a value}"
      shift 2
      ;;
    --allow-fresh)
      # The reason is MANDATORY. A bare --allow-fresh would make the gate
      # switchable with no trace of why, which is the state this whole item
      # exists to end.
      allow_fresh="${2:?--allow-fresh requires a reason, e.g. --allow-fresh \"CVE-2026-1234 fix published today\"}"
      shift 2
      ;;
    --)
      shift
      cmd=("$@")
      break
      ;;
    -h|--help)
      sed -n '2,49p' "$0"
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
# Header gets normalized from `# # ---` to `# ---`; commented DOMAIN lines get
# their comment marker stripped. Idempotent on already-open sections.
#
# The domain pattern is deliberately strict and is the SAME shape as
# list_denied_domains() in scripts/profile.sh — anchored both ends, one optional
# leading dot, an alphabetic TLD of two or more characters, nothing else on the
# line. Two parsers reading one file must agree on what a domain line IS, and
# profile.sh was already strict; this one was not, which is the bug below.
#
# It used to strip `# ` from EVERY commented line inside the block, which meant
# a section's own prose became allowlist entries for the life of the window.
# Measured 2026-08-18 against the real file: all 25 tagged sections leaked prose
# this way. `[grants-gov]` was the sharp end — a documentation line reading
# `# api.grants.gov   production REST (search2 / fetchOpportunity) …` opened as
# a live line, and Squid splits an ACL line on whitespace, so `production`,
# `REST` and `(search2` each became a dstdomain entry. The file header has
# warned since it was written that inline comments break Squid; nothing enforced
# it, because the only thing that ever uncommented a line did not check.
#
# The failure was quiet in the direction that matters. The junk entries match no
# host, the trap restores the file verbatim afterwards, and the domains you
# asked for do open — so a window looks like it worked. What it costs is the
# config load: if Squid rejects the widened file, `squid -k reconfigure` keeps
# the OLD config and returns success, and the run then fails at
# require_window_enforced naming a domain rather than the line that broke it.
#
# Prose is now left alone. Lines that carry a domain PLUS trailing text — the
# `# host.example   note` form under [antigravity] and [grants-gov] — are also
# left alone, which is the intended reading: both blocks document them as manual
# candidates ([grants-gov]'s three are already live below their own comments),
# not as part of the section's open set. Writing one as a real entry means
# writing it on its own line, exactly as the file header has always required.
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
    inside && /^#[[:space:]]+\.?[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z][A-Za-z]+[[:space:]]*$/ {
      sub(/^#[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      print
      next
    }
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

# gate3_scan_file <file> — Gate 3 (Python wheels-only) opt-outs declared in ONE file.
#
# BYTE-IDENTICAL with the copy in scripts/verify-sandbox.sh, deliberately.
# verify-sandbox.sh is STREAMED into the container over stdin (profile.sh
# `verify`), so it can neither source this file nor have it mounted; the parser
# has to exist twice. with-egress.test.sh extracts both bodies and diffs them
# exactly, because two hand-edited parsers over one grammar drift — the two
# agent deny lists already proved that here. Edit both or neither.
#
# Emits `key=value<TAB>CLASS`, and emits NOTHING for a file that declares no
# opinion. Silence is the wanted state: a project inheriting the image default
# is the healthy case, and a check that fires on every healthy repo becomes
# furniture (the G10 and N03 lesson, learned twice).
#
# Classes: OK (as strong as the default) · WEAKER (a per-package exemption —
# pip only; uv has no per-package key, re-confirmed against uv 0.12.5, whose
# only `--no-build*` relatives are the unrelated build-isolation flags) · OFF
# (the wholesale opt-out) · UNPARSED (could not tell, which is never a pass).
#
# python3 rather than grep because this is SECTION-SCOPED: `no-build = false`
# under [tool.hatch], inside a comment, or in a string is not an opt-out, and a
# line-grep cannot tell those apart from the real thing. The file is parsed,
# never executed. stderr is deliberately NOT swallowed — a parser that dies
# silently under-reports, which reads exactly like a clean tree.
gate3_scan_file() {
  python3 - "$1" <<'PY'
import configparser, os, sys, tomllib

path = sys.argv[1]
name = os.path.basename(path)
out = []

def emit(key, val, cls):
    out.append("%s=%s\t%s" % (key, val, cls))

try:
    if name == "pip.conf":
        cp = configparser.ConfigParser(strict=False)
        cp.read(path)
        only_binary = no_binary = None
        for sect in cp.sections():
            if cp.has_option(sect, "only-binary"):
                only_binary = (cp.get(sect, "only-binary") or "").strip()
            if cp.has_option(sect, "no-binary"):
                no_binary = (cp.get(sect, "no-binary") or "").strip()
        # A pip.conf in the tree REPLACES /etc/pip.conf wherever it is in
        # effect (PIP_CONFIG_FILE, a CI step, a tox env) rather than merging
        # with it, so the wheels-only default is simply absent there. pip does
        # not read it from the CWD on its own — which is exactly why this
        # reports and never blocks.
        if only_binary is None:
            emit("only-binary", "<unset>", "OFF")
        elif only_binary == ":all:":
            emit("only-binary", only_binary, "OK")
        else:
            emit("only-binary", only_binary, "WEAKER")
        if no_binary:
            emit("no-binary", no_binary, "WEAKER")
    else:
        with open(path, "rb") as fh:
            data = tomllib.load(fh)
        table = data if name == "uv.toml" else (data.get("tool") or {}).get("uv") or {}
        if not isinstance(table, dict):
            table = {}
        if "no-build" in table:
            v = table["no-build"]
            if v is False:
                emit("no-build", "false", "OFF")
            elif v is True:
                emit("no-build", "true", "OK")
            else:
                emit("no-build", str(v), "UNPARSED")
except (OSError, tomllib.TOMLDecodeError, configparser.Error, UnicodeDecodeError) as e:
    emit("parse", type(e).__name__, "UNPARSED")

for row in out:
    print(row)
PY
}

# scan_uv_exclude_newer <dir> — the project's OWN uv age pin, if it has one.
#
# Host-side only, and not a verdict: it exists because this script injects
# UV_EXCLUDE_NEWER (below), env beats `[tool.uv] exclude-newer` in uv's
# precedence (measured 2026-08-24, uv 0.12.5, host and container), and a project
# that pins an OLDER timestamp than the injected window is therefore silently
# LOOSENED by the very gate meant to tighten it. Recording the project's pin in
# the audit record is what makes that visible afterwards; suppressing the
# injection instead would let any workspace turn the gate off by pinning a
# future date, which is the opposite of the intent.
#
# Emits `path<TAB>exclude-newer=<value>`; nothing when no project pins one.
scan_uv_exclude_newer() {
  local dir="$1" f val
  [[ -d "$dir" ]] || return 0
  while IFS= read -r f; do
    val="$(python3 - "$f" <<'PY'
import os, sys, tomllib

path = sys.argv[1]
try:
    with open(path, "rb") as fh:
        data = tomllib.load(fh)
except Exception:
    raise SystemExit(0)
table = data if os.path.basename(path) == "uv.toml" else (data.get("tool") or {}).get("uv") or {}
if isinstance(table, dict) and table.get("exclude-newer"):
    print(table["exclude-newer"])
PY
)" || val=""
    # `[[ ... ]] && printf` as the LAST command in this loop body makes the whole
    # function exit 1 whenever the final file carries no pin — and under this
    # script's `set -e` that killed the run before the window ever opened.
    # Measured on a live profile, 2026-08-24. Locked in with-egress.test.sh.
    if [[ -n "$val" ]]; then
      printf '%s\texclude-newer=%s\n' "${f#$dir/}" "$val"
    fi
  done < <(find "$dir" -maxdepth 4 \( -name uv.toml -o -name pyproject.toml \) \
             -not -path '*/node_modules/*' -not -path '*/.venv/*' \
             -not -path '*/.venv-*/*' -not -path '*/site-packages/*' \
             -not -path '*/.git/*' 2>/dev/null | sort)
}

# scan_workspace_rc <dir> — gate overrides in the tree about to install.
#
# Covers BOTH gates: Gate 2's release-age quarantine (.npmrc /
# pnpm-workspace.yaml) and Gate 3's Python wheels-only policy (uv.toml /
# pyproject.toml / pip.conf, parsed by gate3_scan_file above). Gate 2 was
# defended at three layers and Gate 3 at one; that asymmetry was accidental,
# not decided (work/0008 item 1).
#
# The install is the moment this matters: a child .npmrc or pnpm-workspace.yaml
# that zeroes the quarantine means the packages resolved inside THIS window were
# never held to the age gate, and the audit record would otherwise claim a
# quarantined install. depaudit's N03 and verify's G10 sweep both find these, but
# neither runs here, and this is the only route by which a dependency enters.
#
# Baselines are the sandbox's own constants because the host cannot read the
# container's live npm/pnpm config: npm min-release-age=7 DAYS (/usr/etc/npmrc,
# set in the Dockerfile) and pnpm minimum-release-age=10080 MINUTES
# (~/.config/pnpm/rc, written by profile.sh ensure_state). Same window, 1440x
# apart in unit — do not "harmonise" them.
#
# Emits `path<TAB>key=value<TAB>CLASS` lines; never blocks. A weakened window is
# confidence, not a boundary, and hard-failing the only install route over it
# would break installs to defend against something already reported elsewhere.
scan_workspace_rc() {
  local dir="$1" f key val mins base class row
  [[ -d "$dir" ]] || return 0
  while IFS= read -r f; do
    case "$f" in
      *uv.toml|*pyproject.toml|*pip.conf)
        # Gate 3 (ADR-0004), the Python half of the same finding. An sdist runs
        # setup.py / a PEP-517 backend at INSTALL time, so a project that opts
        # out restores arbitrary code execution for every install inside THIS
        # window — and the audit record would otherwise read as a clean
        # wheels-only install. Under-reporting is the worst failure mode an
        # audit log has, because it is indistinguishable from a clean run.
        while IFS= read -r row; do
          [[ -n "$row" ]] || continue
          printf '%s\t%s\n' "${f#$dir/}" "$row"
        done < <(gate3_scan_file "$f")
        ;;
      *pnpm-workspace.yaml)
        while IFS= read -r line; do
          val="${line#*:}"; val="${val//[[:space:]]/}"
          key="minimumReleaseAge"; base=10080
          if [[ -n "$val" && "$val" != *[!0-9]* ]]; then mins="$val"; else mins=""; fi
          if   [[ -z "$mins" ]];        then class=MALFORMED
          elif (( mins == 0 ));         then class=OFF
          elif (( mins < base ));       then class=WEAKER
          else                               class=OK; fi
          printf '%s\t%s=%s\t%s\n' "${f#$dir/}" "$key" "$val" "$class"
        done < <(grep -hE '^[[:space:]]*minimumReleaseAge[[:space:]]*:' "$f" 2>/dev/null)
        ;;
      *)
        while IFS= read -r line; do
          key="${line%%=*}"; key="${key//[[:space:]]/}"
          val="${line#*=}";  val="${val//[[:space:]]/}"
          case "$key" in
            min-release-age)     base=10080
                                 if [[ -n "$val" && "$val" != *[!0-9]* ]]; then mins=$(( val * 1440 )); else mins=""; fi ;;
            minimum-release-age) base=10080
                                 if [[ -n "$val" && "$val" != *[!0-9]* ]]; then mins="$val"; else mins=""; fi ;;
            *) continue ;;
          esac
          if   [[ -z "$mins" ]];  then class=MALFORMED
          elif (( mins == 0 ));   then class=OFF
          elif (( mins < base )); then class=WEAKER
          else                         class=OK; fi
          printf '%s\t%s=%s\t%s\n' "${f#$dir/}" "$key" "$val" "$class"
        done < <(grep -hE '^[[:space:]]*(min-release-age|minimum-release-age)[[:space:]]*=' "$f" 2>/dev/null)
        ;;
    esac
  done < <(find "$dir" -maxdepth 4 \
             \( -name .npmrc -o -name pnpm-workspace.yaml \
                -o -name uv.toml -o -name pyproject.toml -o -name pip.conf \) \
             -not -path '*/node_modules/*' -not -path '*/.venv/*' \
             -not -path '*/.venv-*/*' -not -path '*/site-packages/*' \
             -not -path '*/.git/*' 2>/dev/null | sort)
}

RC_OVERRIDE_JSON="[]"
posture_preflight() {
  # NB: REPO_ROOT here is the SANDBOX repo, not the workspace parent. The
  # workspace is ${HOME}/repo/<profile>, mounted at /workspace in the agent
  # (docker-compose.yml), which is the tree the install will actually resolve in.
  local rows; rows="$(scan_workspace_rc "${HOME}/repo/$profile")"
  [[ -n "$rows" ]] || return 0

  local bad_rows
  bad_rows="$(printf '%s\n' "$rows" | grep -vE '\tOK$' || true)"
  if [[ -n "$bad_rows" ]]; then
    echo "WARN: the workspace weakens a dependency gate — packages resolved or built in" >&2
    echo "      this window may NOT have been held to the 7-day age gate (Gate 2) or to" >&2
    echo "      the wheels-only policy (Gate 3, ADR-0004 — an sdist runs code at install):" >&2
    printf '%s\n' "$bad_rows" | while IFS=$'\t' read -r p kv c; do
      printf '        %-10s %s  (%s)\n' "$c" "$p" "$kv" >&2
    done
    echo "      Proceeding — this is recorded in the audit log, not enforced here." >&2
  fi

  RC_OVERRIDE_JSON="$(printf '%s\n' "$rows" | python3 -c '
import sys, json
out = []
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    while len(parts) < 3:
        parts.append("")
    out.append({"path": parts[0], "setting": parts[1], "class": parts[2]})
print(json.dumps(out))
' 2>/dev/null || echo '[]')"
}

# --- T24: the Python half of the age gate ----------------------------------
#
# npm gets a RELATIVE 7-day quarantine from `min-release-age=7` in the image.
# uv's equivalent, `exclude-newer`, takes a TIMESTAMP and not a duration, which
# is why it was never set image-wide: a fixed date on an ML sandbox is a
# resolution freeze that rots, and per-project pins go unmaintained (dashboard
# carried a P04 WARN from the day it was written). ADR-0003 makes this script
# the only route a dependency enters a profile by, and it is the one place that
# knows the moment the window opens — so it can do the duration→timestamp
# conversion per window, which no static config can.
#
# MEASURED 2026-08-24, uv 0.12.5, on the host AND in the image:
#   * precedence is env > project `[tool.uv] exclude-newer` > user config, so a
#     workspace file CANNOT switch the injected window off. (This is the
#     opposite of Gate 2 and Gate 3, where the project file wins — do not
#     generalise between them.)
#   * inert under `--frozen`: `uv sync --frozen` performs no resolution and the
#     install plan is byte-identical with and without the variable set. The
#     install shape we most want to encourage is unaffected.
#   * the image carries uv 0.12.5, which honours UV_EXCLUDE_NEWER and ships
#     `uv audit`.
#
# THE ONE UNCOMFORTABLE CONSEQUENCE, recorded rather than hidden: because env
# wins, a project pinning an OLDER (stricter) exclude-newer is silently
# LOOSENED to this window. The alternative — deferring to the project file —
# would let any workspace disable the gate by pinning a future date, which is
# strictly worse. So the project's own pin is read and written into the audit
# record whenever it differs, and said aloud here when it is stricter.
PY_EXCLUDE_NEWER=""
PY_AGE_GATE_JSON='{"applied":false,"reason":"not evaluated"}'
python_age_gate() {
  local pins pin_json
  pins="$(scan_uv_exclude_newer "${HOME}/repo/$profile")"
  pin_json="$(printf '%s\n' "$pins" | python3 -c '
import sys, json
out = []
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    while len(parts) < 2:
        parts.append("")
    out.append({"path": parts[0], "setting": parts[1]})
print(json.dumps(out))
' 2>/dev/null || echo '[]')"

  if [[ -n "$allow_fresh" ]]; then
    echo "→ python age gate: SUPPRESSED for this window — $allow_fresh" >&2
    PY_EXCLUDE_NEWER=""
    PY_AGE_GATE_JSON="$(WE_REASON="$allow_fresh" WE_PINS="$pin_json" python3 -c '
import os, json
print(json.dumps({"applied": False, "reason": os.environ["WE_REASON"],
                  "project_pins": json.loads(os.environ.get("WE_PINS") or "[]")},
                 separators=(",", ":"), sort_keys=True))')"
    return 0
  fi

  PY_EXCLUDE_NEWER="$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                      || date -u -v-7d +%Y-%m-%dT%H:%M:%SZ)"
  echo "→ python age gate: UV_EXCLUDE_NEWER=$PY_EXCLUDE_NEWER (7 days, same window as npm)" >&2

  if [[ -n "$pins" ]]; then
    while IFS=$'\t' read -r p kv; do
      [[ -n "$p" ]] || continue
      if [[ "${kv#exclude-newer=}" < "$PY_EXCLUDE_NEWER" ]]; then
        echo "   ! $p pins ${kv} — STRICTER than this window, and the env var beats it." >&2
        echo "     Its packages resolve to the 7-day window instead. Recorded in the audit line." >&2
      fi
    done <<< "$pins"
  fi

  PY_AGE_GATE_JSON="$(WE_TS="$PY_EXCLUDE_NEWER" WE_PINS="$pin_json" python3 -c '
import os, json
print(json.dumps({"applied": True, "exclude_newer": os.environ["WE_TS"], "window_days": 7,
                  "project_pins": json.loads(os.environ.get("WE_PINS") or "[]")},
                 separators=(",", ":"), sort_keys=True))')"
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
# The definitive check is the enforcement probe below, which now runs alongside
# this one. That earlier note said a probe "needs a section -> canonical-host
# mapping" and was therefore not worth building; that objection was wrong. No
# mapping is needed — diffing the backup against the widened file names the
# domains this run just opened, and squid can be asked about those directly.
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

# newly_opened_domains <backup> <current> — domains this run just uncommented.
#
# Text only, so it is testable offline. Idempotent opens (the section was already
# uncommented) legitimately yield nothing; the caller treats empty as "nothing to
# probe", not as a failure.
newly_opened_domains() {
  local before="$1" after="$2" strip='^[[:space:]]*#|^[[:space:]]*$'
  comm -13 <(grep -vE "$strip" "$before" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^\.//' | sort -u) \
           <(grep -vE "$strip" "$after"  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^\.//' | sort -u)
}

# Is squid ENFORCING the widened list? assert_allowlist_visible above compares
# file bytes, which under the directory mount is very nearly tautological — it
# cannot distinguish "reloaded" from "not reloaded". This can.
#
# Probes one just-opened domain from inside the proxy container and expects
# anything other than 403. Unlike verify's deny sweep this costs a real upstream
# connect, which is free here: the window is open precisely so that host can be
# reached, and the command about to run will connect to it anyway.
#
# Fails CLOSED, consistent with the refusal policy above: an audit record for an
# install that could never have reached its registry is worse than no record.
assert_window_enforced() {
  local domain="$1" code
  code="$(printf '%s\n' "$domain" | timeout 30 docker exec -i "$PROXY" bash -c '
      read -r d
      code=TIMEOUT
      if exec 3<>/dev/tcp/127.0.0.1/3128 2>/dev/null; then
        printf "CONNECT %s:443 HTTP/1.1\r\nHost: %s:443\r\n\r\n" "$d" "$d" >&3
        read -t 5 -r _proto code _rest <&3 || code=TIMEOUT
        exec 3<&- 3>&-
      else
        code=NOCONNECT
      fi
      printf "%s\n" "$code"' 2>/dev/null)" || code=""
  # Only an explicit 403 is a verdict that the ACL still denies the host. A
  # timeout or a 5xx means the request got PAST the ACL and something upstream
  # failed — not an enforcement problem, and not this check's business.
  [[ "$code" != "403" ]]
}

require_window_enforced() {
  local opened first
  opened="$(newly_opened_domains "$backup" "$ALLOWLIST")"
  first="$(printf '%s\n' "$opened" | grep -m1 . || true)"
  [[ -n "$first" ]] || { echo "→ no new domains to probe (sections already open)" >&2; return 0; }

  assert_window_enforced "$first" && {
    echo "→ $PROXY is enforcing the widened list (probed $first)" >&2; return 0; }

  echo "WARN: $PROXY still DENIES $first after a reload — the widened list is not" >&2
  echo "      being enforced. Restarting the proxy and re-probing." >&2
  docker restart "$PROXY" >/dev/null 2>&1 || { echo "ERROR: could not restart $PROXY" >&2; return 1; }
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    assert_window_enforced "$first" && {
      echo "→ $PROXY restarted and now enforcing the widened list" >&2; return 0; }
  done
  echo "ERROR: $PROXY denies $first even after a restart." >&2
  echo "       Refusing to run the command: the window is not actually open, and the" >&2
  echo "       install would fail with an error naming nothing (see docs/squid-internals.md)." >&2
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

# Posture pre-flight: does the workspace itself weaken the age gate? Warn-only,
# recorded in the audit record. Runs here so the finding describes the tree as it
# was when the window opened, not after the install rewrote lockfiles.
posture_preflight

# T24 — compute this window's Python quarantine (and read any project pin it
# will override). Before the window opens, so the timestamp describes the
# window, and so a suppressed gate is announced before anything is reachable.
python_age_gate

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
# Two layers: the file is readable at the expected path (mount health), and squid
# is actually enforcing it (reload health). The second is the decisive one.
require_allowlist_visible || exit 5
require_window_enforced || exit 5

echo "→ exec $AGENT: ${cmd[*]}" >&2
rc=0
# The age gate rides in as an ENV VAR rather than a flag, so it applies to every
# uv invocation the command makes — `uv add`, `uv lock`, `uv pip install`, and
# anything a script inside <cmd> shells out to. A flag would only cover the one
# uv call written on the command line. Empty means suppressed by --allow-fresh:
# passing `-e UV_EXCLUDE_NEWER=` would set it to the empty string, which uv
# rejects, so the array stays empty instead.
gate_env=()
[[ -n "$PY_EXCLUDE_NEWER" ]] && gate_env=(-e "UV_EXCLUDE_NEWER=$PY_EXCLUDE_NEWER")
# ${a[@]+"${a[@]}"} rather than "${a[@]}": under `set -u` an empty array is an
# unbound expansion in bash 3.2, which macolima still runs (docs/sibling-repo-relationship.md).
docker exec ${gate_env[@]+"${gate_env[@]}"} "$AGENT" bash -lc "${cmd[*]}" || rc=$?

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
   WE_PREFLIGHT="$PREFLIGHT_JSON" WE_RC_OVERRIDES="$RC_OVERRIDE_JSON" \
   WE_PY_AGE_GATE="$PY_AGE_GATE_JSON" \
   WE_ALLOWED="$hosts_allowed" WE_DENIED="$hosts_denied" \
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

# Release-age overrides found in the workspace when the window opened. An entry
# whose class is not OK means the packages resolved in this window may not have
# been held to the age gate — without which the record would read as a clean
# quarantined install.
try:
    rc_overrides = json.loads(os.environ.get("WE_RC_OVERRIDES") or "[]")
except json.JSONDecodeError:
    rc_overrides = []

# T24. `applied` answers "was this window quarantined" for Python the way the
# npm side has always been answerable; `reason` is populated only when
# --allow-fresh suppressed it, so an opt-out is legible months later.
# `project_pins` records any exclude-newer the workspace set for itself: the env
# var beats it, so a stricter project pin was LOOSENED to this window and the
# record has to say so rather than imply the project's own window applied.
try:
    py_age_gate = json.loads(os.environ.get("WE_PY_AGE_GATE") or "{}")
except json.JSONDecodeError:
    py_age_gate = {}

rec = {
    "ts_open":   int(os.environ["WE_TS_OPEN"]),
    "ts_close":  int(os.environ["WE_TS_CLOSE"]),
    "duration_s": int(os.environ["WE_TS_CLOSE"]) - int(os.environ["WE_TS_OPEN"]),
    "profile":   os.environ["WE_PROFILE"],
    "sections":  [s for s in os.environ.get("WE_SECTIONS", "").split(",") if s],
    "cmd":       os.environ.get("WE_CMD", ""),
    "rc":        int(os.environ.get("WE_RC") or 0),
    "preflight": preflight,
    "rc_overrides": rc_overrides,
    "py_age_gate": py_age_gate,
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
