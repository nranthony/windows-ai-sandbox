#!/usr/bin/env bash
# =============================================================================
# verify-sandbox.sh — run INSIDE the container to confirm hardening is active
# =============================================================================
# Usage (from host):
#   scripts/profile.sh <profile> verify
# The `verify` subcommand streams this file into the container via stdin
# (`docker exec -i ... bash -s`) because the sandbox repo itself is NOT
# bind-mounted into /workspace — workspace holds per-profile repos only.
#
# Adapted from macolima/scripts/verify-sandbox.sh. Differences for this repo:
#   - container runs as root (UID 0) under rootless Docker userns=host, not UID 1000
#   - bwrap + socat never installed (sandbox-hardening-package §7)
#   - proxy probe uses api.anthropic.com (always on allowlist)
# =============================================================================
set -uo pipefail

PASS=0; FAIL=0; WARN=0
pass() { printf '\033[0;32m[PASS]\033[0m %s\n' "$*"; ((++PASS)); }
fail() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$*"; ((++FAIL)); }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; ((++WARN)); }
# Checks that don't apply on this substrate (e.g. GPU on bare Linux) — printed
# for visibility, counted in no bucket so tallies stay comparable across hosts.
note() { printf '\033[0;36m[ N/A]\033[0m %s\n' "$*"; }

# --- identity ----------------------------------------------------------------
# Root-in-container is intentional here (rootless Docker userns=host maps
# container UID 0 to host UID 1000). See docs/sandbox-design-notes.md.
UID_IN=$(id -u)
[[ "$UID_IN" -eq 0 ]] && pass "running as root (intended under rootless Docker)" \
                    || warn "unexpected UID $UID_IN (expected 0)"

# Verify userns mapping actually maps 0 to host 1000 (not to rootful root).
# Rootless Docker emits a two-line map: "0 1000 1" (container root → host UID 1000)
# followed by "1 100000 65536" (subuid range for non-root container UIDs). Only the
# first line is load-bearing for the security boundary, so check that explicitly.
UID0_MAP=$(awk 'NR==1{$1=$1; print}' /proc/self/uid_map 2>/dev/null)
if [[ "$UID0_MAP" == "0 1000 1" ]]; then
  pass "uid_map: container UID 0 = host UID 1000 (rootless)"
elif [[ "$UID0_MAP" == "0 0 "* ]]; then
  # Container root IS host root — rootful Docker with no userns remap. The
  # headline boundary (escape lands as an unprivileged host user) is gone;
  # this must never silently pass the rest of the suite. Hard fail.
  fail "uid_map: container UID 0 = host UID 0 (ROOTFUL Docker, no userns remap — sandbox boundary absent; use rootless Docker)"
else
  warn "uid_map line 1 unexpected: '$UID0_MAP' (full map: $(tr '\n' '|' < /proc/self/uid_map))"
fi

# --- rootfs ------------------------------------------------------------------
ROOT_OPTS=$(awk '$2=="/"{print $4; exit}' /proc/mounts)
case ",$ROOT_OPTS," in
  *,ro,*) warn "rootfs read-only (unexpected — compose changed?)" ;;
  *,rw,*) pass "rootfs writable (intended — non-root userns + cap_drop is the boundary)" ;;
  *)      warn "rootfs mount flags unparsed: $ROOT_OPTS" ;;
esac

# --- /tmp writable, noexec --------------------------------------------------
if touch /tmp/.t 2>/dev/null; then rm -f /tmp/.t; pass "/tmp writable (tmpfs)"; else fail "/tmp not writable"; fi
TMP_OPTS=$(awk '$2=="/tmp"{print $4; exit}' /proc/mounts)
case ",$TMP_OPTS," in
  *,noexec,*) pass "/tmp mounted noexec" ;;
  *)          warn "/tmp missing noexec: $TMP_OPTS" ;;
esac

# --- capabilities -----------------------------------------------------------
CAP_EFF=$(grep '^CapEff:' /proc/self/status | awk '{print $2}')
[[ "$CAP_EFF" == "0000000000000000" ]] && pass "CapEff=0 (cap_drop: ALL effective)" \
                                       || warn "CapEff=$CAP_EFF"

# --- no-new-privileges ------------------------------------------------------
NNP=$(grep '^NoNewPrivs:' /proc/self/status | awk '{print $2}')
[[ "$NNP" == "1" ]] && pass "NoNewPrivs=1" || fail "NoNewPrivs=$NNP"

# --- seccomp ----------------------------------------------------------------
SM=$(grep '^Seccomp:' /proc/self/status | awk '{print $2}')
[[ "$SM" == "2" ]] && pass "seccomp mode 2 (filtered)" || fail "seccomp not active (mode=$SM)"

# --- pids limit -------------------------------------------------------------
PM=$(cat /sys/fs/cgroup/pids.max 2>/dev/null || echo unknown)
[[ "$PM" != "max" && "$PM" != "unknown" ]] && pass "pids.max=$PM" || warn "pids.max=$PM"

# --- egress -----------------------------------------------------------------
# Direct internet must fail (sandbox-internal is internal: true).
if curl -s --connect-timeout 3 --noproxy '*' https://api.github.com >/dev/null 2>&1; then
  fail "direct internet reachable (sandbox-internal not internal?)"
else
  pass "direct internet blocked (sandbox-internal internal: true)"
fi

# Proxied request to an allowlisted domain should succeed.
if curl -s --connect-timeout 5 https://api.anthropic.com >/dev/null 2>&1; then
  pass "proxied request to allowed domain works (api.anthropic.com)"
else
  warn "proxied request failed — check allowed_domains.txt / egress-proxy running"
fi

# Disallowed domain should be refused by the proxy.
if curl -s --connect-timeout 5 https://example.com >/dev/null 2>&1; then
  fail "disallowed domain (example.com) reachable — allowlist misconfigured"
else
  pass "disallowed domain blocked by proxy"
fi

# --- deny-destructive PreToolUse hook ---------------------------------------
# File invariants (baked into image at /usr/local/lib/claude-hooks/):
HOOK=/usr/local/lib/claude-hooks/deny-destructive.sh
if [[ -x "$HOOK" ]]; then
  pass "deny-destructive hook present and executable ($HOOK)"
  HMODE=$(stat -c '%a' "$HOOK" 2>/dev/null || echo "?")
  [[ "$HMODE" == "755" ]] && pass "deny-destructive hook mode 0755" \
                          || warn "deny-destructive hook mode $HMODE (expected 755)"
  # Behavioural assertion: a find -delete envelope must yield a deny decision.
  HOOK_OUT=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"find /tmp -delete"}}' | "$HOOK" 2>/dev/null || true)
  if printf '%s' "$HOOK_OUT" | grep -q '"permissionDecision":"deny"'; then
    pass "deny-destructive hook blocks find -delete"
  else
    fail "deny-destructive hook did NOT block find -delete (output: $HOOK_OUT)"
  fi
else
  fail "deny-destructive hook missing or not executable at $HOOK (rebuild image)"
fi

# --- deliberately-absent tools ----------------------------------------------
# ssh: openssh-client purged in Dockerfile so VS Code's SSH_AUTH_SOCK
# forwarding has no tool to weaponize even if the host setting reverts.
command -v bwrap  >/dev/null && fail "bwrap present (should be uninstalled — audit §7)"  || pass "bwrap absent (intended)"
command -v socat  >/dev/null && fail "socat present (should be uninstalled — audit §7)"  || pass "socat absent (intended)"
command -v ssh    >/dev/null && fail "ssh present (openssh-client should be purged)"     || pass "ssh absent (intended)"

# --- expected tools ---------------------------------------------------------
command -v claude >/dev/null && pass "claude CLI present" || fail "claude CLI missing"
command -v gh     >/dev/null && pass "gh CLI present"     || fail "gh CLI missing"
command -v glab   >/dev/null && pass "glab CLI present"   || fail "glab CLI missing"
command -v uv     >/dev/null && pass "uv present"         || fail "uv missing"
command -v just   >/dev/null && pass "just present"       || fail "just missing"
command -v bd     >/dev/null && pass "bd (beads) present" || fail "bd (beads) missing"

# just shebang recipes must run despite /tmp being noexec: just writes the
# recipe script to $TMPDIR then execs it, so the baked /usr/local/bin/just
# wrapper repoints TMPDIR at an exec-allowed dir. Regression guard for that fix.
if command -v just >/dev/null; then
  JT=$(mktemp -d)
  printf '%s\n' 'r:' '    #!/usr/bin/env bash' '    echo shebang_ok' > "$JT/justfile"
  if [[ "$(cd "$JT" && just r 2>/dev/null)" == "shebang_ok" ]]; then
    pass "just shebang recipe executes (noexec /tmp worked around)"
  else
    fail "just shebang recipe blocked — /tmp noexec + missing tempdir wrapper (os error 13)?"
  fi
  rm -rf "$JT"
fi

# --- GPU passthrough sanity -------------------------------------------------
# GPU is a WSL2-overlay concern (docker-compose.wsl-gpu.yml). Both artifacts
# present = overlay active. Both absent: disambiguate via SANDBOX_HOST_GPU
# (substrate metadata the base compose passes through from profile.sh) —
# host had /dev/dxg but the container has neither artifact means the overlay
# silently failed to layer (SANDBOX_GPU=0 left set, or compose run outside
# profile.sh): WARN, the drift the old per-artifact warns used to catch.
# Genuinely GPU-less host = N/A, not a warning. Partial = overlay drift.
if [[ -e /dev/dxg && -d /usr/lib/wsl/lib ]]; then
  pass "GPU passthrough active (/dev/dxg + /usr/lib/wsl/lib — WSL2 overlay)"
elif [[ ! -e /dev/dxg && ! -d /usr/lib/wsl/lib ]]; then
  if [[ "${SANDBOX_HOST_GPU:-0}" == "1" ]]; then
    warn "host exposes /dev/dxg but container has no GPU passthrough — wsl-gpu overlay not layered (SANDBOX_GPU=0 set? compose run without profile.sh?)"
  else
    note "GPU passthrough not layered (bare-Linux host)"
  fi
else
  warn "GPU passthrough partial: /dev/dxg $([[ -e /dev/dxg ]] && echo present || echo missing), /usr/lib/wsl/lib $([[ -d /usr/lib/wsl/lib ]] && echo present || echo missing) — wsl-gpu overlay drift?"
fi

# --- host gitconfig NOT leaked (audit Finding B) ----------------------------
if [[ -f /root/.gitconfig ]]; then
  warn "/root/.gitconfig exists — VS Code may have copied host config (set dev.containers.copyGitConfig: false)"
else
  pass "no leaked /root/.gitconfig"
fi

# --- SSH agent forwarding NOT enabled (audit Finding A) ---------------------
# Two signals here — VS Code can leave either the env var or the socket
# file behind, and in some attach flows one appears without the other.
if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
  fail "SSH_AUTH_SOCK=$SSH_AUTH_SOCK (disable VS Code remote.SSH.enableAgentForwarding)"
else
  pass "SSH_AUTH_SOCK unset (no agent forwarding)"
fi
# shellcheck disable=SC2144 -- glob check, not iteration
if ls /tmp/vscode-ssh-auth-*.sock >/dev/null 2>&1; then
  fail "VS Code SSH auth socket present in /tmp"
else
  pass "no VS Code SSH auth socket in /tmp"
fi

# --- git credential.helper NOT injected (audit Finding C) -------------------
# Query git's RESOLVED config across ALL layers — system /etc/gitconfig, global
# $GIT_CONFIG_GLOBAL, and any repo-local .git/config under cwd — via
# `--show-origin --get-all`, not just one file. An injected helper in any layer
# is caught (a single-file grep missed /etc/gitconfig and repo-local configs).
# Plus a belt: grep the global file directly, in case GIT_CONFIG_GLOBAL is unset
# and the injected line is latent (git wouldn't resolve it, but it's still a
# risk). Benign in-container helpers (gh/glab write
# `!/usr/local/bin/gh auth git-credential`) are expected and use the sandbox's
# own tokens. We flag only host-reaching shims: VS Code Dev Containers' IPC
# shim (vscode-server / vscode-remote-containers) and host credential managers
# (git-credential-manager; osxkeychain kept for macolima parity).
cred_pat='vscode-server|vscode-remote-containers|git-credential-manager|osxkeychain'
resolved_helpers="$(git config --show-origin --get-all credential.helper 2>/dev/null || true)"
file_helpers=""
[[ -f /root/.config/git/config ]] && \
  file_helpers="$(grep -E 'helper[[:space:]]*=' /root/.config/git/config 2>/dev/null || true)"
if printf '%s\n%s\n' "$resolved_helpers" "$file_helpers" | grep -qE "$cred_pat"; then
  fail "host-reaching credential.helper detected (resolved git config or global file) — VS Code shim/host helper; init-profile-state.sh ensure_state should strip it"
else
  pass "no host-reaching credential.helper (resolved across system/global/local + global-file belt)"
fi

# --- git identity is a noreply address (no personal email in commits) -------
# ensure_state seeds/enforces [user] in the GIT_CONFIG_GLOBAL file on every
# `up`; this tripwire catches drift (hand edits, tool rewrites, VS Code
# copyGitConfig) that would stamp a personal email onto commits authored
# inside the sandbox. Resolved config, so any layer that wins is checked.
id_email="$(git config user.email 2>/dev/null || true)"
if [[ "$id_email" == *@users.noreply.github.com ]]; then
  pass "git user.email is a noreply address ($id_email)"
elif [[ -z "$id_email" ]]; then
  fail "git user.email unset — identity seed missing (rerun 'profile.sh <p> up')"
else
  fail "git user.email '$id_email' is not a users.noreply.github.com address — personal email would leak into commits"
fi

# ---------------------------------------------------------------------------
# Gate 2 — dependency-resolution quarantine (slopsquat defence).
# dependency-guardrails T12 (docs/_archive/dependency-guardrails-plan.md). These assert the LIVE values, because the
# agent runs as root here and can edit both /usr/etc/npmrc (image layer) and
# ~/.config/pnpm/rc (bind mount). The config is defence-in-depth, not a kernel
# boundary — this tripwire is what makes drift surface within one `up`.
# Purely local: no network call, so it still runs with egress down.
# ---------------------------------------------------------------------------
# UNITS ARE DIFFERENT AND BOTH ARE VERIFIED FROM SOURCE (2026-07-31):
#   npm  min-release-age     = DAYS.    man 7 config: "only versions that were
#                              available more than the given number of days ago".
#   pnpm minimum-release-age = MINUTES. pnpm.cjs:
#                              new Date(Date.now() - minimumReleaseAge * 60 * 1e3)
# So 7 (npm) and 10080 (pnpm) are the SAME 7-day window. Do not "harmonise" them.
NPM_AGE="$(npm config get min-release-age 2>/dev/null || echo '')"
case "$NPM_AGE" in
  ''|null|undefined)
    fail "npm min-release-age unset — freshly-published packages resolve with no quarantine (expected 7 DAYS; see Dockerfile 'Gate 2')" ;;
  *[!0-9]*)
    fail "npm min-release-age='$NPM_AGE' is not a plain integer — the value is a NUMBER OF DAYS, and a suffixed form (7d, 1w) does not parse" ;;
  *)
    if [[ "$NPM_AGE" -ge 1 ]]; then pass "npm min-release-age=$NPM_AGE day(s)"
    else fail "npm min-release-age=$NPM_AGE — quarantine disabled"; fi ;;
esac

# A non-integer here is worse than "off": pnpm computes the cutoff as
# `value * 60 * 1e3`, so a suffixed string ("0s", "7d") yields NaN and
# `new Date(NaN)` = Invalid Date. Every comparison against it is false, so pnpm
# rejects EVERY version and no install can resolve at all. Fails closed and
# looks like a broken registry. Hard FAIL, with the fix in the message.
PNPM_AGE="$(pnpm config get minimumReleaseAge 2>/dev/null || echo '')"
case "$PNPM_AGE" in
  ''|null|undefined)
    fail "pnpm minimum-release-age unset — pnpm resolves with no quarantine (expected 10080 MINUTES; see init-profile-state.sh)" ;;
  *[!0-9]*)
    fail "pnpm minimum-release-age='$PNPM_AGE' is not a plain integer — pnpm computes value*60*1e3, so a suffixed form gives Invalid Date and REJECTS EVERY VERSION (no install can resolve). Use plain minutes, e.g. 10080 for 7 days" ;;
  *)
    if [[ "$PNPM_AGE" -ge 1440 ]]; then pass "pnpm minimum-release-age=$PNPM_AGE min ($((PNPM_AGE/1440)) day(s))"
    elif [[ "$PNPM_AGE" -ge 1 ]]; then fail "pnpm minimum-release-age=$PNPM_AGE MINUTES (<1 day) — looks like days were entered where MINUTES are required (1440 = 24h, 10080 = 7d); quarantine is effectively off"
    else fail "pnpm minimum-release-age=$PNPM_AGE — quarantine disabled"; fi ;;
esac

# G10: a PROJECT .npmrc beats our global /usr/etc/npmrc (precedence is
# cli > env > project > user > global), so any repo under /workspace can switch
# the quarantine off for itself — silently, and without touching anything this
# sandbox owns. Verified 2026-07-31: a project file with min-release-age=0 takes
# `npm config get min-release-age` from 7 to 0.
#
# COMPARE, do not merely report. The first version of this check warned on the
# PRESENCE of any project release-age setting, which made it unactionable: a repo
# doing the right thing (committing a window so it also applies outside this
# sandbox, per plan 04) got the same warning as one switching the gate off, so
# the line became permanent furniture. Warn only when the project value is
# WEAKER than the global; a value that meets or beats it is the wanted state.
#
# Still never FAIL: the workspace is the user's own repo and may have a
# considered reason. This reports; the human decides.
if [[ -d /workspace ]]; then
  # Baselines in MINUTES. Read with the explicit global flags — a plain
  # `npm config get` is CWD-sensitive and a project .npmrc overrides it, so a
  # weak file would end up compared against itself and pass. Verified 2026-08-02:
  # inside a dir with min-release-age=1, `config get` says 1 and
  # `config get --location=global` still says 7.
  # npm counts DAYS, pnpm counts MINUTES (see the block above) — normalise.
  g_npm_d="$(npm config get --location=global min-release-age 2>/dev/null || echo '')"
  g_pnpm_m="$(pnpm config get --global minimum-release-age 2>/dev/null || echo '')"
  if [[ -n "$g_npm_d" && "$g_npm_d" != *[!0-9]* ]]; then g_npm_m=$(( g_npm_d * 1440 )); else g_npm_m=""; fi
  [[ -n "$g_pnpm_m" && "$g_pnpm_m" != *[!0-9]* ]] || g_pnpm_m=""

  fmt_window() {  # minutes -> human-readable window
    if   (( $1 == 0 ));    then printf 'OFF'
    elif (( $1 < 60 ));    then printf '%dmin' "$1"
    elif (( $1 < 1440 ));  then printf '%dh'   "$(( $1 / 60 ))"
    else                        printf '%dd'   "$(( $1 / 1440 ))"; fi
  }

  weaker=""; malformed=""; uncomparable=""; ok_count=0
  # Both file kinds carry the same setting under different spellings and units:
  #   .npmrc              min-release-age=<DAYS> | minimum-release-age=<MINUTES>
  #   pnpm-workspace.yaml minimumReleaseAge: <MINUTES>
  # A pnpm workspace file in a monorepo CHILD is as effective an override as an
  # .npmrc, and was invisible here until 2026-08-03.
  while IFS= read -r rc; do
    case "$rc" in
      *pnpm-workspace.yaml) pat='^[[:space:]]*minimumReleaseAge[[:space:]]*:' ; sep=':' ;;
      *)                    pat='^[[:space:]]*(min-release-age|minimum-release-age)[[:space:]]*=' ; sep='=' ;;
    esac
    while IFS= read -r line; do
      key="${line%%${sep}*}"; key="${key//[[:space:]]/}"
      val="${line#*${sep}}";  val="${val//[[:space:]]/}"
      case "$key" in
        min-release-age)     base="$g_npm_m"
                             if [[ -n "$val" && "$val" != *[!0-9]* ]]; then mins=$(( val * 1440 )); else mins=""; fi ;;
        minimum-release-age|minimumReleaseAge)
                             base="$g_pnpm_m"
                             if [[ -n "$val" && "$val" != *[!0-9]* ]]; then mins="$val"; else mins=""; fi ;;
        *) continue ;;
      esac
      label="${rc#/workspace/} [$key=$val]"
      if   [[ -z "$mins" ]]; then malformed="${malformed}${label}  "
      elif [[ -z "$base" ]]; then uncomparable="${uncomparable}${label}  "
      elif (( mins < base )); then
        weaker="${weaker}${label} = $(fmt_window "$mins") vs global $(fmt_window "$base");  "
      else ok_count=$(( ok_count + 1 ))
      fi
    done < <(grep -hE "$pat" "$rc" 2>/dev/null)
  done < <(find /workspace -maxdepth 4 \( -name .npmrc -o -name pnpm-workspace.yaml \) \
             -not -path '*/node_modules/*' 2>/dev/null)

  # A non-integer is worse than a weak value: pnpm computes value*60*1e3, so a
  # suffixed form yields NaN -> Invalid Date -> every version rejected.
  [[ -n "$malformed" ]] && warn "project config has a NON-INTEGER release-age — pnpm computes value*60*1e3, so this yields Invalid Date and REJECTS EVERY VERSION (presents as a broken registry): $malformed"
  [[ -n "$weaker" ]] && warn "project config WEAKENS the global quarantine (project > global): $weaker"
  [[ -n "$uncomparable" ]] && warn "project config sets a release-age but the global baseline is unreadable, so it cannot be compared: $uncomparable"
  if [[ -z "$malformed$weaker$uncomparable" ]]; then
    if (( ok_count > 0 )); then
      pass "$ok_count project release-age setting(s) under /workspace meet or beat the global quarantine"
    else
      pass "no project .npmrc / pnpm-workspace.yaml overriding the release-age quarantine under /workspace"
    fi
  fi
  unset -f fmt_window
fi

# npm 12 blocks lifecycle scripts by default via the allow-scripts allowlist.
# That is where a slopsquat payload runs, so losing it matters more than the
# age gate. Empty list = nothing may run scripts (the wanted state).
NPM_SCRIPTS="$(npm config get allow-scripts 2>/dev/null || echo '')"
if [[ "$NPM_SCRIPTS" == '[""]' || -z "$NPM_SCRIPTS" ]]; then
  pass "npm install scripts blocked (allow-scripts=${NPM_SCRIPTS:-empty})"
else
  warn "npm allow-scripts=$NPM_SCRIPTS — packages in this list run install scripts"
fi

# extra-index-url is a dependency-confusion vector: pip may prefer whichever
# index offers the higher version. Its ABSENCE is the control.
if [[ -f /etc/pip.conf ]]; then
  if grep -qE '^[[:space:]]*extra-index-url' /etc/pip.conf; then
    fail "/etc/pip.conf sets extra-index-url — dependency-confusion vector; remove it"
  else
    pass "pip index pinned, no extra-index-url"
  fi
else
  warn "/etc/pip.conf absent — pip index not pinned (see Dockerfile 'Gate 2')"
fi

# Gate 3 (Python): wheels only. An sdist runs setup.py at INSTALL time — the
# Python analogue of the npm lifecycle scripts already blocked above. Both tools
# need asserting because they share no configuration: uv reads /etc/uv/uv.toml
# and no pip config at all; pip reads /etc/pip.conf. Checking one would leave the
# other silently open, and uv is the primary installer on this image.
if [[ -f /etc/uv/uv.toml ]]; then
  if grep -qE '^[[:space:]]*no-build[[:space:]]*=[[:space:]]*true' /etc/uv/uv.toml; then
    pass "uv wheels-only (no-build=true) — source builds refused"
  else
    fail "/etc/uv/uv.toml exists but does not set no-build=true — uv will build sdists, running setup.py at install time (Dockerfile 'Gate 3')"
  fi
else
  fail "/etc/uv/uv.toml absent — uv will build source distributions (Dockerfile 'Gate 3'). uv reads NO pip config, so /etc/pip.conf does not cover it"
fi

# BEHAVIOURAL assertion for the same gate, because the file check above can pass
# while the gate is off.
#
# MEASURED 2026-08-03 on uv 0.12.0 in this image: `UV_NO_SYSTEM_CONFIG=1` makes uv
# ignore /etc/uv/uv.toml entirely, and a source build that is otherwise refused
# ("Building source distributions is disabled") installs cleanly. The env var is
# undocumented in `uv help`. It never touches the file, so the grep above still
# reports PASS — the exact shape of failure this repo keeps re-learning: a config
# that looks correct and does nothing.
#
# So: actually try to build a trivial local package and require the refusal.
# ~0.1s, no network (`--offline`), nothing fetched and nothing of the package's
# code executed — the point is that uv REFUSES before any build runs.
#
# Honest about scope: this proves enforcement in THIS environment. The agent is
# root in-container and can set its own env per command, so no in-container check
# can prevent the bypass — same standing as every other config gate here
# (defence-in-depth, not the boundary; see ARCHITECTURE.md). What it does buy is
# that the gate cannot be silently off for the whole container without saying so.
if command -v uv >/dev/null 2>&1; then
  _uvg=/root/.uv-gate-probe
  rm -rf "$_uvg"; mkdir -p "$_uvg/pkg/src/gateprobe"
  printf '[build-system]\nrequires = ["setuptools>=61"]\nbuild-backend = "setuptools.build_meta"\n[project]\nname = "gateprobe"\nversion = "0.0.1"\n' \
    > "$_uvg/pkg/pyproject.toml"
  : > "$_uvg/pkg/src/gateprobe/__init__.py"
  if uv venv "$_uvg/v" >/dev/null 2>&1; then
    _uvout=$(uv pip install --python "$_uvg/v/bin/python" --offline "$_uvg/pkg" 2>&1)
    if printf '%s' "$_uvout" | grep -q 'source distributions is disabled'; then
      pass "uv wheels-only is ENFORCED (a source build was refused, not just configured)"
    elif printf '%s' "$_uvout" | grep -qE '^ \+ gateprobe|Installed 1 package'; then
      fail "uv BUILT a source distribution despite /etc/uv/uv.toml — Gate 3 is not in effect (check UV_NO_SYSTEM_CONFIG / UV_NO_BUILD in the environment: $(env | grep -oE 'UV_[A-Z_]+' | tr '\n' ' '))"
    else
      warn "uv wheels-only could not be confirmed behaviourally (probe output: $(printf '%s' "$_uvout" | tail -1))"
    fi
  else
    warn "uv wheels-only not confirmed behaviourally — could not create a probe venv"
  fi
  rm -rf "$_uvg"
  # A persistent bypass in the container's own environment would make every
  # install in this session unguarded, and unlike a per-command env var it is
  # visible from here.
  if [[ -n "${UV_NO_SYSTEM_CONFIG:-}" ]]; then
    fail "UV_NO_SYSTEM_CONFIG is set in the container environment — uv ignores /etc/uv/uv.toml, so Gate 3's uv half is off for every install in this session"
  fi
fi

if [[ -f /etc/pip.conf ]]; then
  if grep -qE '^[[:space:]]*only-binary[[:space:]]*=[[:space:]]*:all:' /etc/pip.conf; then
    # An exemption is legitimate but must be visible — same discipline as npm's
    # allow-scripts allowlist (depaudit N11: an exemption needs a stated reason).
    pip_exempt=$(grep -E '^[[:space:]]*no-binary[[:space:]]*=' /etc/pip.conf | sed 's/.*=[[:space:]]*//')
    if [[ -n "$pip_exempt" ]]; then
      warn "pip wheels-only, but exempts: $pip_exempt — each exemption builds from source; confirm the reason is recorded"
    else
      pass "pip wheels-only (only-binary=:all:), no exemptions"
    fi
  else
    fail "/etc/pip.conf does not set only-binary=:all: — pip will build sdists (Dockerfile 'Gate 3')"
  fi
fi

echo ""
echo "== $PASS passed | $FAIL failed | $WARN warnings =="
[[ $FAIL -eq 0 ]]
