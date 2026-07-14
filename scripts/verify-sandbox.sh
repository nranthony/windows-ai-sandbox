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

echo ""
echo "== $PASS passed | $FAIL failed | $WARN warnings =="
[[ $FAIL -eq 0 ]]
