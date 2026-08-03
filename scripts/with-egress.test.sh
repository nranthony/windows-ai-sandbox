#!/usr/bin/env bash
# =============================================================================
# with-egress.test.sh — regression harness for the phase-3 instrumentation
# =============================================================================
# Covers the two PARSERS in scripts/with-egress.sh, which are the parts that can
# be wrong while looking right:
#
#   extract_specs()  T18 — which package names does a command actually name?
#   egress_hosts()   T20 — which hosts did the proxy see inside the bracket?
#
# Plus the third allowlist parser, which lives in profile.sh but belongs with
# these because it reads the same file and fails the same way:
#
#   list_denied_domains()  — which domains does the repo mean to DENY? This
#     feeds verify's enforcement probe, so a parser that over-matches reports a
#     healthy proxy as permitting revoked hosts (crying wolf), and one that
#     under-matches verifies nothing while printing a reassuring count.
#
# This is not incidental caution. The identical class of bug has now shipped
# three times on this workstream: T04's dep-name extractor was line-oriented and
# silently matched nothing on compact manifests; depaudit's lockfile parser put
# peer-dependency suffixes into package names so 121 of 869 entries were queried
# under names OSV cannot match and every one reported clean. A parser that
# under-matches does not fail — it returns a confident empty answer.
#
# The functions are EXTRACTED FROM THE REAL SCRIPT at run time rather than
# copied, so this cannot drift from what actually ships.
#
# Fully offline. No docker, no network, no profile required.
#
# Usage:  bash scripts/with-egress.test.sh
# =============================================================================

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/with-egress.sh"
PROFILE_SRC="$HERE/profile.sh"
[[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 1; }
[[ -f "$PROFILE_SRC" ]] || { echo "missing $PROFILE_SRC" >&2; exit 1; }

# Pull a top-level `name() { ... }` block out of a real script and define it
# here. Anchored on column-0 braces, which is how both files are written.
# Second argument is the source file; it defaults to with-egress.sh because most
# of what this suite covers lives there, but the allowlist parsers are split
# across two scripts and both are locked here (see the header).
import_fn() {
  local fn="$1" src="${2:-$SRC}" body
  body="$(awk -v f="$fn" '
    $0 ~ "^" f "\\(\\) \\{" { inside = 1 }
    inside { print }
    inside && /^\}$/ { exit }
  ' "$src")"
  [[ -n "$body" ]] || { echo "could not extract $fn() from $src" >&2; exit 1; }
  eval "$body"
}
import_fn extract_specs
import_fn egress_hosts
import_fn list_denied_domains "$PROFILE_SRC"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf "  ok   %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf "  FAIL %s\n       want: %s\n       got : %s\n" "$1" "$2" "$3"; }

# expect_specs <description> <command> <expected multiline "eco name", or "">
expect_specs() {
  local desc="$1" cmd="$2" want="$3" got
  got="$(extract_specs "$cmd")"
  if [[ "$got" == "$want" ]]; then ok "$desc"
  else bad "$desc" "$(printf '%s' "$want" | tr '\n' '; ')" "$(printf '%s' "$got" | tr '\n' '; ')"; fi
}

printf "\n-- T18 extract_specs: explicit names ARE caught --\n"
expect_specs "npm install one package"      'npm install lodash'            'npm lodash'
expect_specs "npm i shorthand"              'npm i lodash'                  'npm lodash'
expect_specs "pnpm add scoped + version"    'pnpm add @scope/pkg@1.2.3'     'npm @scope/pkg'
expect_specs "pip install pinned"           'pip install requests==2.31.0'  'pypi requests'
expect_specs "pip install range"            'pip install "django>=4.0"'     'pypi django'
expect_specs "uv pip install"               'uv pip install httpx'          'pypi httpx'
expect_specs "uv add"                       'uv add rich'                   'pypi rich'
expect_specs "poetry add"                   'poetry add flask'              'pypi flask'
expect_specs "cargo add"                    'cargo add serde'               'cargo serde'
expect_specs "yarn add"                     'yarn add react'                'npm react'
expect_specs "bun add"                      'bun add hono'                  'npm hono'
expect_specs "multiple packages, sorted"    'npm install alpha beta'        'npm alpha
npm beta'
expect_specs "after a cd, && chained"       'cd /workspace/x && npm install lodash' 'npm lodash'
expect_specs "two installs, ; separated"    'pip install one; npm add two'  'npm two
pypi one'

printf "\n-- T18 extract_specs: things that must NOT be reported --\n"
# A lockfile install names nothing new: every version in it was already held to
# the age gate when it was written. Reporting them would make every `npm ci`
# emit a wall of UNKNOWNs, and a noisy check is one nobody reads (see the G10
# rewrite).
expect_specs "npm ci is a lockfile install"     'npm ci'                          ''
expect_specs "bare pnpm install"                'pnpm install'                    ''
expect_specs "pnpm install --frozen-lockfile"   'pnpm install --frozen-lockfile'  ''
expect_specs "uv sync"                          'uv sync --frozen'                ''
expect_specs "flags are not packages"           'pip install --upgrade --no-cache-dir' ''
expect_specs "local path install"               'pip install -e .'                ''
expect_specs "local relative path"              'pip install ./libs/thing'        ''
expect_specs "extras on a local path"           'uv pip install -e ".[dev]"'      ''
expect_specs "no install verb at all"           'python -c "import sys"'          ''
expect_specs "unrelated command containing npm" 'echo npm is a package manager'   ''
expect_specs "a shell variable cannot resolve"  'pip install $PKG'                ''
expect_specs "a glob cannot resolve"            'pip install ./dist/*.whl'        ''

printf "\n-- T20 egress_hosts: squid logformat parsing --\n"
# Real lines, copied from a live egress-proxy access.log. Field 1 is
# epoch.millis, field 4 is code/status, field 7 is the URL.
LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT
cat > "$LOG" <<'EOF'
1785722053.249      0 172.30.187.2 TCP_DENIED/403 3394 CONNECT example.com:443 - HIER_NONE/- text/html
1785722086.631     60 172.30.187.2 TCP_TUNNEL/200 3875 CONNECT api.anthropic.com:443 - HIER_DIRECT/160.79.104.10 -
1785722090.000     10 172.30.187.2 TCP_MISS/200 900 GET http://pypi.org/simple/foo/ - HIER_DIRECT/1.2.3.4 text/html
1785722095.500     12 172.30.187.2 TCP_TUNNEL/200 100 CONNECT files.pythonhosted.org:443 - HIER_DIRECT/9.9.9.9 -
1785722099.100      0 172.30.187.2 TCP_DENIED/403 100 CONNECT evil.example.net:443 - HIER_NONE/- text/html
1785722100.063     12 172.30.187.2 TCP_TUNNEL/200 100 CONNECT last-fraction.example:443 - HIER_DIRECT/7.7.7.7 -
1785799999.000      0 172.30.187.2 TCP_TUNNEL/200 100 CONNECT after-the-window.com:443 - HIER_DIRECT/8.8.8.8 -
1785700000.000      0 172.30.187.2 TCP_TUNNEL/200 100 CONNECT before-the-window.com:443 - HIER_DIRECT/8.8.8.8 -
EOF
# Stub docker so egress_hosts() runs its real awk against the fixture. It calls
# `docker exec -u proxy <proxy> awk -v s=.. -v e=.. '<prog>' <logpath>`.
docker() {
  local args=("$@") prog="" i
  for (( i=0; i<${#args[@]}; i++ )); do
    [[ "${args[$i]}" == "awk" ]] && { prog_idx=$((i+5)); break; }
  done
  # args: exec -u proxy <proxy> awk -v s=S -v e=E <prog> <path>
  awk "${args[5]}" "${args[6]}" "${args[7]}" "${args[8]}" "${args[9]}" "$LOG"
}
PROXY="stub"
got="$(egress_hosts 1785722053 1785722100)"
want='allowed api.anthropic.com
allowed files.pythonhosted.org
allowed last-fraction.example
allowed pypi.org
denied evil.example.net
denied example.com'
if [[ "$got" == "$want" ]]; then
  ok "hosts split allowed/denied, scheme+path+port stripped, bracket honoured"
else
  bad "egress_hosts" "$(printf '%s' "$want" | tr '\n' '; ')" "$(printf '%s' "$got" | tr '\n' '; ')"
fi

# REGRESSION LOCK. squid logs epoch.MILLISECONDS; `date +%s` truncates. With an
# inclusive `$1 <= e` bound, every request in the closing fractional second is
# dropped. Measured 2026-08-03: a successful `uv pip install six` reached
# pypi.org at .063 past the close and the audit record read "0 hosts" — an
# under-reporting audit log is indistinguishable from a clean run, which makes
# it worse than no log. `last-fraction.example` is logged at 1785722100.063
# against a bracket ending at 1785722100 and MUST appear.
if printf '%s\n' "$got" | grep -q 'last-fraction.example'; then
  ok "traffic in the closing fractional second is included  <-- REGRESSION LOCK"
else
  bad "closing fractional second dropped" "last-fraction.example present" "absent"
fi

# The bracket is the whole point: traffic from a previous or later window must
# not be attributed to this one.
if printf '%s\n' "$got" | grep -qE 'after-the-window|before-the-window'; then
  bad "bracket excludes out-of-window traffic" "neither host" "one leaked in"
else
  ok "bracket excludes traffic before and after the window"
fi

printf "\n-- container-side allowlist path agrees everywhere --\n"
# The path lives in FIVE places and nothing at runtime cross-checks them. Every
# one of the consumers fails SILENTLY on a mismatch rather than erroring:
#   profile.sh inode check  -> `stat` fails, ctr_ino is empty, check skipped forever
#   profile.sh content diff -> degrades to a warn, drift detection goes soft-blind
#   with-egress.sh          -> refuses every install (the whole ADR-0003 route)
#   dashboard               -> domain count returns None, post-reload assert stops asserting
# So a typo here is not a crash, it is a security control quietly switching off.
ROOT="$(cd "$HERE/.." && pwd)"
mount_target="$(grep -oE '^\s*- \./proxy:[^:]+:ro' "$ROOT/docker-compose.yml" | sed 's|.*:/|/|;s|:ro||')"
acl_path="$(grep -oE 'dstdomain "[^"]+"' "$ROOT/proxy/squid.conf" | sed 's/.*"\(.*\)"/\1/')"
sh_profile="$(grep -oE '^PROXY_ALLOWLIST="[^"]+"' "$ROOT/scripts/profile.sh" | sed 's/.*"\(.*\)"/\1/')"
sh_egress="$(grep -oE '^PROXY_ALLOWLIST="[^"]+"' "$ROOT/scripts/with-egress.sh" | sed 's/.*"\(.*\)"/\1/')"
py_dash="$(grep -oE '^PROXY_ALLOWLIST = "[^"]+"' "$ROOT/dashboard/src/lib/docker_client.py" | sed 's/.*"\(.*\)"/\1/')"

for pair in "compose-mount:$mount_target" "squid.conf-acl:$acl_path" \
            "profile.sh:$sh_profile" "with-egress.sh:$sh_egress" "dashboard:$py_dash"; do
  if [[ -n "${pair#*:}" ]]; then ok "found ${pair%%:*} -> ${pair#*:}"
  else bad "could not read the path from ${pair%%:*}" "a path" "empty"; fi
done

if [[ "$sh_profile" == "$sh_egress" && "$sh_egress" == "$py_dash" && "$py_dash" == "$acl_path" ]]; then
  ok "squid.conf acl and all three code constants agree"
else
  bad "allowlist path disagrees across call sites" \
      "all equal" "acl=$acl_path profile=$sh_profile egress=$sh_egress dash=$py_dash"
fi

if [[ -n "$mount_target" && "$acl_path" == "$mount_target/"* ]]; then
  ok "the acl path lives inside the compose mount target"
else
  bad "acl path is not under the mount target" "$mount_target/..." "$acl_path"
fi

# A directory mount is the whole fix; a file mount reintroduces silent blindness.
if grep -qE '^\s*- \./proxy/allowed_domains\.txt:' "$ROOT/docker-compose.yml"; then
  bad "allowlist is bind-mounted as a FILE again" "directory mount ./proxy:...:ro" "single-file mount"
else
  ok "allowlist is not mounted as a single file  <-- REGRESSION LOCK"
fi

# Nothing may still reach for the pre-2026-08-03 location. Excludes this file
# (which names the old path in the pattern above) and __pycache__ (stale .pyc
# bytecode is not a source reference and regenerates on next import).
stale="$(grep -rln --exclude='with-egress.test.sh' --exclude-dir='__pycache__' \
  '/etc/squid/allowed_domains\.txt' \
  "$ROOT/scripts" "$ROOT/dashboard" "$ROOT/docker-compose.yml" "$ROOT/proxy" 2>/dev/null || true)"
if [[ -z "$stale" ]]; then
  ok "no code references the old /etc/squid/allowed_domains.txt path"
else
  bad "stale path references remain" "none" "$(printf '%s' "$stale" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# list_denied_domains() — the enforcement probe's input set
# ---------------------------------------------------------------------------
# Every case below is a shape that actually occurs in proxy/allowed_domains.txt.
# The two that matter most are the last two: they are false-FAIL generators, and
# a false FAIL on every healthy profile is how a check becomes furniture.
echo
echo "list_denied_domains() — denied-set parser"

DENYFIX="$(mktemp -d "${TMPDIR:-/tmp}/denyfix.XXXXXX")"
trap 'rm -rf "$DENYFIX"' EXIT

cat > "$DENYFIX/allowlist.txt" <<'EOF'
# =============================================================================
# Prose header. Not a domain. Mentions example.com in passing, with words.
# =============================================================================
api.anthropic.com
github.com
api.github.com

# # --- Playwright browser binaries [playwright-install] ---
# # Used by `playwright install chromium` etc.
# cdn.playwright.dev
# playwright.download.prss.microsoft.com

# --- Quarto CLI install [quarto-install] ---
# github.com
# objects.githubusercontent.com

# --- Python package ecosystem [pypi] ---
# .files.pythonhosted.org

# --- Wildcard-covered child ---
.covered.example
# child.covered.example
EOF

expect_denied() {
  local desc="$1" want="$2" got
  got="$(list_denied_domains "$DENYFIX/allowlist.txt" | sort | tr '\n' ' ' | sed 's/ $//')"
  if [[ "$got" == "$want" ]]; then ok "$desc"; else bad "$desc" "$want" "$got"; fi
}

expect_denied "denied set: commented domains only, traps excluded" \
  "cdn.playwright.dev files.pythonhosted.org objects.githubusercontent.com playwright.download.prss.microsoft.com"

# Spelled out individually so a regression names the specific trap it hit.
got_all="$(list_denied_domains "$DENYFIX/allowlist.txt")"
for probe in "example.com:prose comment is not a domain" \
             "Playwright:double-commented '# #' section header is not a domain" \
             "github.com:commented under one tag but ACTIVE under another" \
             "child.covered.example:covered by an active .wildcard parent" \
             "api.anthropic.com:active domain is not in the denied set"; do
  needle="${probe%%:*}"; why="${probe#*:}"
  if printf '%s\n' "$got_all" | grep -qx "$needle"; then
    bad "excluded: $why" "$needle absent" "$needle present"
  else
    ok "excluded: $why"
  fi
done

# files.pythonhosted.org is written `# .files.pythonhosted.org` — a commented
# wildcard. Squid would match the bare parent too, so probe it without the dot.
if printf '%s\n' "$got_all" | grep -qx 'files.pythonhosted.org'; then
  ok "included: commented wildcard, leading dot stripped for the probe"
else
  bad "included: commented wildcard, leading dot stripped" "files.pythonhosted.org" "absent"
fi

# The real file must yield a non-empty set, or the probe silently verifies
# nothing while reporting success.
real_count="$(list_denied_domains "$ROOT/proxy/allowed_domains.txt" | grep -c . || true)"
if [[ "$real_count" -gt 0 ]]; then
  ok "real allowlist yields a non-empty denied set ($real_count domains)"
else
  bad "real allowlist denied set" "at least 1 domain" "0 — probe would verify nothing"
fi

# github.com is the live instance of the commented-here-active-there trap.
if list_denied_domains "$ROOT/proxy/allowed_domains.txt" | grep -qx 'github.com'; then
  bad "real allowlist: github.com excluded" "absent (active under [git])" "present — would false-FAIL"
else
  ok "real allowlist: github.com excluded  <-- FALSE-FAIL LOCK"
fi

printf "\n  %d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
