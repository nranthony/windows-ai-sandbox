#!/usr/bin/env bash
# =============================================================================
# verify-sandbox.sh — run INSIDE the container to confirm hardening is active
# =============================================================================
# Usage (from host):
#   scripts/profile.sh <profile> exec bash /workspace/windows-ai-sandbox/scripts/verify-sandbox.sh
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

# --- identity ----------------------------------------------------------------
# Root-in-container is intentional here (rootless Docker userns=host maps
# container UID 0 to host UID 1000). See .devcontainer/ROOTLESS-DOCKER-NOTES.md.
UID_IN=$(id -u)
[[ "$UID_IN" -eq 0 ]] && pass "running as root (intended under rootless Docker)" \
                    || warn "unexpected UID $UID_IN (expected 0)"

# Verify userns mapping actually maps 0 to host 1000 (not to rootful root).
UID_MAP=$(cat /proc/self/uid_map 2>/dev/null | tr -s ' ' | sed 's/^ //')
if [[ "$UID_MAP" == "0 1000 1" ]]; then
  pass "uid_map: container UID 0 = host UID 1000 (rootless)"
else
  warn "uid_map unexpected: '$UID_MAP'"
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

# --- deliberately-absent tools ----------------------------------------------
command -v bwrap  >/dev/null && fail "bwrap present (should be uninstalled — audit §7)"  || pass "bwrap absent (intended)"
command -v socat  >/dev/null && fail "socat present (should be uninstalled — audit §7)"  || pass "socat absent (intended)"

# --- expected tools ---------------------------------------------------------
command -v claude >/dev/null && pass "claude CLI present" || fail "claude CLI missing"
command -v gh     >/dev/null && pass "gh CLI present"     || fail "gh CLI missing"
command -v glab   >/dev/null && pass "glab CLI present"   || fail "glab CLI missing"
command -v uv     >/dev/null && pass "uv present"         || fail "uv missing"

# --- GPU passthrough sanity -------------------------------------------------
[[ -e /dev/dxg ]]             && pass "/dev/dxg present (WSL2 GPU device)" || warn "/dev/dxg missing"
[[ -d /usr/lib/wsl/lib ]]     && pass "/usr/lib/wsl/lib mounted"            || warn "/usr/lib/wsl/lib missing"

# --- host gitconfig NOT leaked (audit Finding B) ----------------------------
if [[ -f /root/.gitconfig ]]; then
  warn "/root/.gitconfig exists — VS Code may have copied host config (set dev.containers.copyGitConfig: false)"
else
  pass "no leaked /root/.gitconfig"
fi

# --- SSH agent forwarding NOT enabled (audit Finding A) ---------------------
if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
  warn "SSH_AUTH_SOCK=$SSH_AUTH_SOCK (disable VS Code remote.SSH.enableAgentForwarding)"
else
  pass "no SSH agent forwarding"
fi

# --- git credential.helper NOT injected (audit Finding C) -------------------
if grep -Eq '^\s*helper\s*=' /root/.config/git/config 2>/dev/null; then
  fail "git credential.helper present in config — scrub failed"
else
  pass "no git credential.helper injected"
fi

echo ""
echo "== $PASS passed | $FAIL failed | $WARN warnings =="
[[ $FAIL -eq 0 ]]
