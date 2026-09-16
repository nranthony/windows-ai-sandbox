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

# seccomp.json is an allowlist with no test suite, so a syscall dropped from it
# is invisible until something breaks at the point of use. GNU tar creates its
# archive with creat(2) — denied by OMISSION until 2026-08-28, which made
# `tar -cf <file>` fail EPERM in every profile with a message that reads as a
# capability problem (work/0017). Behavioural, not a grep of the JSON: the file
# on the host says nothing about the profile a RUNNING container was started
# with. `tar -cf - > file` deliberately is not used here — it is the workaround,
# and it passes either way.
if command -v tar >/dev/null; then
  TT=$(mktemp -d)
  : > "$TT/probe"
  if tar -cf "$TT/probe.tar" -C "$TT" probe 2>/dev/null; then
    pass "tar -cf <file> writes an archive (creat allowed)"
  else
    fail "tar -cf <file> EPERM — creat missing from seccomp.json? (work/0017)"
  fi
  rm -rf "$TT"
fi

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

# --- agent backend / ollama sibling -----------------------------------------
# Which model is Claude Code actually talking to? ANTHROPIC_BASE_URL comes from
# the profile's secrets.env (read at container CREATE — recreate after editing),
# so it is invisible from the host repo and worth stating out loud on every
# verify. The controls this repo owns — deny lists, the hook engine, seccomp,
# egress — are all on the harness, not the model, so a backend switch does not
# weaken them. What it DOES change is documented by Anthropic: MCP tool search
# is off by default and model IDs pass through unvalidated.
if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
  case "$ANTHROPIC_BASE_URL" in
    http://ollama:11434)
      pass "agent backend: ollama sibling ($ANTHROPIC_BASE_URL)" ;;
    https://*)
      # Not fatal — openrouter.ai, for one, is already allowlisted. But the
      # host has to BE on the allowlist or squid refuses the CONNECT and every
      # request fails with no clue as to why, so name it rather than nod.
      warn "agent backend: $ANTHROPIC_BASE_URL — non-first-party backend; MCP tool search off, model IDs unvalidated — and the host must be allowlisted or every request fails silently" ;;
    *)
      # Plain http to anything but the sibling means an unencrypted API key on
      # the wire, to a host that is not the one air-gapped service we trust.
      fail "agent backend: $ANTHROPIC_BASE_URL — plain http to something other than the ollama sibling" ;;
  esac
else
  pass "agent backend: Anthropic API (default)"
fi

# Name resolution. `ollama` resolves through Docker's embedded DNS on the
# compose network (resolv.conf is 127.0.0.11 with the sinkhole as its
# upstream — same-network service names answer, everything else dies), so it
# resolves even on an agent created before the extra_hosts entry existed. The
# entry is belt-and-braces against that resolver, not the only path. Measured
# 2026-09-03: an agent with no `ollama` extra_host still resolved .40.
if getent hosts ollama >/dev/null 2>&1; then
  pass "ollama name resolves ($(getent hosts ollama | awk '{print $1; exit}'))"
else
  fail "ollama does not resolve — neither embedded DNS nor extra_hosts answered; recreate the agent (scripts/profile.sh <p> recreate)"
fi

# NO_PROXY is the check that catches a STALE agent. env is fixed at container
# create, so an agent created before `ollama` joined NO_PROXY sends
# http://ollama:11434 through squid, which answers 403 for a non-allowlisted
# host — every Claude Code request against the sibling fails, while the
# --noproxy probe below still passes. Measured 2026-09-03 on exactly that agent.
case ",${NO_PROXY:-}," in
  *,ollama,*) pass "NO_PROXY includes ollama (direct, not via squid)" ;;
  *) fail "NO_PROXY='${NO_PROXY:-}' lacks ollama — agent predates the compose change; http://ollama:11434 is being sent through squid (403). Recreate: scripts/profile.sh <p> recreate" ;;
esac

# Reachability. Absence is NOT a failure: the sibling is opt-in per profile.
# --noproxy '*' is the point of the probe as much as the port is — a reply here
# proves the NO_PROXY bypass works and the call is not being CONNECTed through
# squid, which would deny a non-allowlisted host.
OLLAMA_VER=$(curl -s --noproxy '*' --connect-timeout 3 http://ollama:11434/api/version 2>/dev/null || true)
if [[ -n "$OLLAMA_VER" ]]; then
  pass "ollama sibling answers on http://ollama:11434 direct, not via squid ($OLLAMA_VER)"
else
  note "ollama sibling not running (enable with scripts/profile.sh <p> ollama enable)"
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

# --- antigravity (`agy`) policy ---------------------------------------------
# Two layers, and the ORDER of importance is the reverse of the intuition:
# permissions.deny in the agy settings.json is the layer that must be complete,
# because a workspace .agents/hooks.json can disable the hook by name (measured
# — work/0010 Phase 0) and nothing in a workspace can reach settings.json.
AGY_HOOK=/usr/local/lib/sandbox-hooks/guardrails.sh
AGY_HOOKS_JSON=/root/.gemini/config/hooks.json
AGY_SETTINGS=/root/.gemini/antigravity-cli/settings.json

if [[ -x "$AGY_HOOK" ]]; then
  pass "antigravity guardrails engine present and executable ($AGY_HOOK)"
  # Pass-through must be an explicit allow. `{}` is a DENY to agy, so a script
  # that emitted the claude pass-through here would block every tool call.
  AGY_PASS=$(printf '%s' '{"toolCall":{"name":"run_command","args":{"CommandLine":"ls -la"}}}' \
             | "$AGY_HOOK" --dialect=antigravity 2>/dev/null || true)
  if printf '%s' "$AGY_PASS" | grep -q '"decision":"allow"'; then
    pass "antigravity pass-through is an explicit allow (not {}, which agy reads as deny)"
  else
    fail "antigravity pass-through wrong (output: $AGY_PASS) — every tool call would be blocked"
  fi
  # NOTE these probe the ENVELOPE rules, which are the hook's job. Command
  # prefixes (npm install, curl, bash -c) are the static permissions.deny
  # layer's job and are asserted against settings.json further down — the two
  # layers are deliberately not duplicated, so do not "fix" this by expecting
  # the hook to block an installer.
  for probe in \
    'run_command|{"toolCall":{"name":"run_command","args":{"CommandLine":"rm -rf /workspace/x"}}}|recursive rm' \
    'run_command|{"toolCall":{"name":"run_command","args":{"CommandLine":"find /tmp -delete"}}}|find -delete' \
    'view_file|{"toolCall":{"name":"view_file","args":{"AbsolutePath":"/root/.gemini/antigravity-cli/antigravity-oauth-token"}}}|read of the agy oauth token' \
    'write_to_file|{"toolCall":{"name":"write_to_file","args":{"TargetFile":"/workspace/x/.agents/hooks.json","CodeContent":"{}"}}}|workspace hooks.json write'
  do
    _env=${probe#*|}; _label=${_env#*|}; _env=${_env%|*}
    _out=$(printf '%s' "$_env" | "$AGY_HOOK" --dialect=antigravity 2>/dev/null || true)
    if printf '%s' "$_out" | grep -q '"decision":"deny"'; then
      pass "antigravity hook blocks $_label"
    else
      fail "antigravity hook did NOT block $_label (output: $_out)"
    fi
  done
  # Fail-CLOSED tripwire. agy blocks the tool call when a hook misbehaves, so a
  # garbage envelope must not come back as an allow.
  AGY_JUNK=$(printf '%s' 'not json at all' | "$AGY_HOOK" --dialect=antigravity 2>/dev/null || true)
  if printf '%s' "$AGY_JUNK" | grep -q '"decision":"allow"'; then
    fail "antigravity hook failed OPEN on a malformed envelope (output: $AGY_JUNK)"
  else
    pass "antigravity hook fails closed on a malformed envelope"
  fi
else
  fail "antigravity guardrails engine missing at $AGY_HOOK (rebuild image)"
fi

if [[ -s "$AGY_HOOKS_JSON" ]] && jq -e '."sandbox-guardrails".enabled == true' "$AGY_HOOKS_JSON" >/dev/null 2>&1; then
  pass "antigravity hooks.json seeded and enabled ($AGY_HOOKS_JSON)"
else
  fail "antigravity hooks.json missing, invalid, or disabled — run (host): profile.sh <p> converge"
fi

if [[ -s "$AGY_SETTINGS" ]] && jq -e '(.permissions.deny // []) | length > 0' "$AGY_SETTINGS" >/dev/null 2>&1; then
  pass "antigravity permissions.deny present ($(jq -r '.permissions.deny | length' "$AGY_SETTINGS") rules)"
  # The static layer is the tamper-resistant one; spot-check a representative
  # from each deny category rather than the whole list (the parity suite owns
  # completeness, offline).
  _missing=""
  for g in 'command(curl)' 'command(npm install)' 'command(bash -c)' 'command(git push)'; do
    jq -e --arg g "$g" '.permissions.deny | index($g)' "$AGY_SETTINGS" >/dev/null 2>&1 || _missing="$_missing $g"
  done
  [[ -z "$_missing" ]] && pass "antigravity deny list covers network/installer/shell-escape/remote-vcs" \
                       || fail "antigravity deny list missing:$_missing — run (host): profile.sh <p> converge"
else
  fail "antigravity permissions.deny absent from $AGY_SETTINGS — run (host): profile.sh <p> converge"
fi

# --- antigravity upstream-contract drift ------------------------------------
# `agy` self-updates, and its hook contract is an upstream API: a renamed tool
# or a changed decision enum disarms the guardrail while every offline suite
# stays green. This check belongs HERE rather than in `just check-upstreams`
# because the thing to compare against is inside the image — agy embeds its own
# customization docs as literal strings — and check-upstreams is offline by
# contract (it reads sibling checkouts, never docker).
#
# It asserts the five tool names the engine dispatches on, and the decision
# enum it emits, still exist in the shipped binary. It cannot prove semantics
# have not changed; it catches the rename, which is the failure that is
# otherwise silent.
AGY_BIN=$(command -v agy 2>/dev/null || echo /usr/local/bin/agy)
if [[ -x "$AGY_BIN" ]]; then
  _drift=""
  for _tok in run_command write_to_file replace_file_content view_file grep_search \
              PreToolUse force_ask; do
    grep -aqm1 -- "$_tok" "$AGY_BIN" 2>/dev/null || _drift="$_drift $_tok"
  done
  if [[ -z "$_drift" ]]; then
    pass "antigravity hook contract intact (tool names + decision enum still in the binary)"
  else
    fail "antigravity hook contract DRIFT — absent from $AGY_BIN:$_drift (the guardrail may no longer match; re-run work/0010 Phase 0)"
  fi
else
  warn "agy binary not found at $AGY_BIN — cannot check hook-contract drift (a SKIP is not a pass)"
fi

# A workspace hooks.json outranks the global one and can disable it by name.
# The hook blocks the write; this catches one that got there another way.
_wshooks=$(find /workspace -maxdepth 4 \( -path '*/.agents/hooks.json' -o -path '*/.agent/hooks.json' \
             -o -path '*/_agents/hooks.json' -o -path '*/_agent/hooks.json' \) 2>/dev/null | head -5)
if [[ -z "$_wshooks" ]]; then
  pass "no workspace hooks.json shadowing the antigravity guardrail"
else
  fail "workspace hooks.json found (outranks the global guardrail and can disable it by name): $(printf '%s' "$_wshooks" | tr '\n' ' ')"
fi

# --- the converge discard capture is EXPECTED, not a leftover ---------------
# /root/.claude/settings.discarded.json is written by the host-side policy
# convergence (work/0011): the keys the Claude template does not own, captured
# before the overwrite that drops them. It is here so a lost grant is
# recoverable from disk rather than from scrollback, and it is named here so
# nobody deletes it as debris or mistakes it for a stale backup — the same
# argument as the no-`*.bak*` assertion below, in the opposite direction.
#
# It is recovery capture, NOT audit evidence: this path is inside the container
# mount and the agent can write it. The authoritative drift signal is the
# host-side owned-key comparison in `profile.sh <p> verify`.
DISCARDED=/root/.claude/settings.discarded.json
if [[ -s "$DISCARDED" ]]; then
  note "converge discard capture present ($DISCARDED) — expected; it records what the last policy converge dropped"
else
  note "no converge discard capture ($DISCARDED) — nothing has been dropped since the last one was cleared"
fi

# --- no backup copies inside the scanned skills dir -------------------------
# ADR-0005, measured in-container 2026-08-10 (claude 2.1.223): a `<name>.bak*`
# sibling in ~/.claude/skills/ is a SECOND LIVE COPY, and for a skills-dir
# plugin the BACKUP wins the name race — the fresh copy reports
# "✘ Not loaded — same plugin name". The failure is silent: the skill list looks
# populated, and the body being executed is the stale one.
#
# converge_skills prunes these on every `up`, but its pattern is `*.bak.*` —
# an UNSTAMPED `myconv.bak`, or anything created in-container after the last
# convergence, survives it. That gap is exactly what this check exists to catch,
# which is why it runs here and not only in the host-side test suite.
SKILLS_DIR=/root/.claude/skills
if [[ -d "$SKILLS_DIR" ]]; then
  BAKS=$(find "$SKILLS_DIR" -maxdepth 1 -name '*.bak*' 2>/dev/null)
  if [[ -z "$BAKS" ]]; then
    pass "no backup copies beside the seeded skills ($SKILLS_DIR)"
  else
    fail "backup copies in $SKILLS_DIR shadow the live skill (a plugin backup WINS the name race — ADR-0005): $(printf '%s' "$BAKS" | tr '\n' ' ')
       fix from the host: scripts/profile.sh <profile> converge"
  fi
else
  warn "$SKILLS_DIR missing — skills were never seeded (host: scripts/profile.sh <profile> converge)"
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

# ADR-0013: the environment names the venv. Compose sets
# UV_PROJECT_ENVIRONMENT=.venv-sandbox so this container's uv builds and uses
# <repo>/.venv-sandbox and never touches <repo>/.venv — the HOST's venv. On this
# substrate the host and the image are both Ubuntu 24.04, so a shared .venv can
# LOOK healthy from both sides until one of them switches interpreter and uv
# silently rebuilds it for the other. Exact value, and RELATIVE: unset is the
# destructive state; an absolute path would put every repo in one shared venv;
# any other name is a venv slot the hosts, the hook's disposable carve-out and
# the scan don't know about. A per-command override by the agent is possible
# and not visible from here — this proves the container-wide default, which is
# what compose owns.
case "${UV_PROJECT_ENVIRONMENT:-}" in
  .venv-sandbox) pass "UV_PROJECT_ENVIRONMENT=.venv-sandbox (uv here never touches the host's .venv)" ;;
  "")            fail "UV_PROJECT_ENVIRONMENT is unset — uv here would target each repo's .venv, the HOST's venv, and recreate it (ADR-0013; set in docker-compose.yml, needs a recreate)" ;;
  /*)            fail "UV_PROJECT_ENVIRONMENT is absolute ($UV_PROJECT_ENVIRONMENT) — every repo would share one venv; it must be the relative .venv-sandbox (ADR-0013)" ;;
  *)             fail "UV_PROJECT_ENVIRONMENT=$UV_PROJECT_ENVIRONMENT, expected .venv-sandbox — hosts, the deletion hook and workspace-scan all key on that name (ADR-0013)" ;;
esac

# ADR-0015: the sandbox notice is written into Claude Code's GLOBAL home —
# never into a repo — from one template, on every up/recreate/rebuild/converge:
#   ~/.claude/CLAUDE.md   auto-loaded every session from any cwd.
# (agy's documented global rules root was measured NOT loaded, 2026-09-16, so
# there is no agy copy to check; a stale ~/.gemini/config/rules/sandbox-notice.md
# left from before the measurement is harmless and unchecked.)
# Three ways this goes wrong, all checked here:
#   missing        — converge never ran for this profile, so the agent is gated
#                    but not briefed;
#   legacy marker  — the BEGIN line still names a sandbox ("managed by macolima"
#                    / "managed by windows-ai-sandbox"). Two sandboxes writing
#                    two different markers is what made one sync APPEND a second
#                    block instead of replacing the first;
#   stale content  — the markers are right but the text between them is behind
#                    the template.
# This script cannot see the repo, so the template's sha256 is handed in by
# profile.sh's verify arm as NOTICE_SHA. sync-agent-notice.sh writes the region
# between the markers byte-for-byte from that template, so the digest of the
# lines strictly between BEGIN and END must equal it. Run by hand (no
# profile.sh), NOTICE_SHA is empty and the markers are still checked.
NOTICE_BEGIN='<!-- BEGIN sandbox-notice (managed by the sandbox — do not edit here) -->'
NOTICE_END='<!-- END sandbox-notice -->'
for _nf in "$HOME/.claude/CLAUDE.md"; do
  if [[ ! -f "$_nf" ]]; then
    fail "sandbox-notice missing: $_nf — the agent is gated but not briefed; run \`converge\`"
    continue
  fi
  if grep -qE '^<!-- BEGIN sandbox-notice.*managed by (macolima|windows-ai-sandbox)' "$_nf"; then
    fail "sandbox-notice in $_nf carries a legacy marker; run \`converge\`"
    continue
  fi
  if ! grep -qF "$NOTICE_BEGIN" "$_nf" || ! grep -qF "$NOTICE_END" "$_nf"; then
    fail "sandbox-notice markers missing/incomplete in $_nf; run \`converge\`"
    continue
  fi
  if [[ -z "${NOTICE_SHA:-}" ]]; then
    warn "sandbox-notice present with current markers: $_nf (NOTICE_SHA not provided — marker checks only)"
    continue
  fi
  # awk prints each in-region line with its newline, so the stream is exactly
  # the template's bytes (content + trailing newline).
  _nsha=$(awk -v beg="$NOTICE_BEGIN" -v end="$NOTICE_END" '
    index($0, end) == 1 { inb = 0 }
    inb { print }
    index($0, beg) == 1 { inb = 1 }
  ' "$_nf" | sha256sum | awk '{print $1}')
  if [[ "$_nsha" == "$NOTICE_SHA" ]]; then
    pass "sandbox-notice current in $_nf"
  else
    fail "sandbox-notice in $_nf is stale vs the template; run \`converge\`"
  fi
done
unset _nf _nsha

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

# G10p: the PYTHON half of G10, and the reason work/0008 item 1 exists. Gate 2's
# project-level override was defended in three places (here, with-egress.sh's
# scan_workspace_rc, depaudit's N03); Gate 3's was defended in none. The
# asymmetry was accidental, not decided.
#
# What it catches: a repo under /workspace carrying `no-build = false` (uv.toml
# or [tool.uv]) or a pip.conf without `only-binary = :all:`. Either restores
# source builds for that project — an sdist runs setup.py / a PEP-517 backend at
# INSTALL time, which is the Python analogue of the npm lifecycle script this
# image already blocks (ADR-0004). The system-file and behavioural probes above
# say nothing about it: they assert the IMAGE default, and a project override is
# precisely what beats an image default.
#
# WARN, never FAIL — same standing as G10. The workspace is the user's own repo
# and may have a considered reason; this reports, the human decides. Silence on
# a project that declares nothing is the wanted state (the N03 lesson: a check
# that fires on every healthy repo is furniture).
#
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

if [[ -d /workspace ]]; then
  if command -v python3 >/dev/null 2>&1; then
    g3_off=""; g3_weaker=""; g3_unparsed=""; g3_ok=0
    while IFS= read -r g3f; do
      while IFS=$'\t' read -r g3kv g3cls; do
        [[ -n "$g3kv" ]] || continue
        g3label="${g3f#/workspace/} [$g3kv]"
        case "$g3cls" in
          OFF)      g3_off="${g3_off}${g3label}  " ;;
          WEAKER)   g3_weaker="${g3_weaker}${g3label}  " ;;
          UNPARSED) g3_unparsed="${g3_unparsed}${g3label}  " ;;
          *)        g3_ok=$(( g3_ok + 1 )) ;;
        esac
      done < <(gate3_scan_file "$g3f" 2>/dev/null)
    done < <(find /workspace -maxdepth 4 \
               \( -name uv.toml -o -name pyproject.toml -o -name pip.conf \) \
               -not -path '*/node_modules/*' -not -path '*/.venv/*' \
               -not -path '*/.venv-*/*' -not -path '*/site-packages/*' \
               -not -path '*/.git/*' 2>/dev/null)

    [[ -n "$g3_off" ]] && warn "project config OPTS OUT of wheels-only (project > /etc/uv/uv.toml, /etc/pip.conf): $g3_off— installs there build from source, running setup.py at install time (ADR-0004)"
    [[ -n "$g3_weaker" ]] && warn "project config exempts package(s) from wheels-only: $g3_weaker— each exemption builds from source; confirm the reason is recorded"
    [[ -n "$g3_unparsed" ]] && warn "project config could not be parsed, so its wheels-only stance is UNKNOWN (never read an unknown as a pass): $g3_unparsed"
    if [[ -z "$g3_off$g3_weaker$g3_unparsed" ]]; then
      if (( g3_ok > 0 )); then
        pass "$g3_ok project wheels-only setting(s) under /workspace match the image default"
      else
        pass "no project uv.toml / pyproject.toml / pip.conf under /workspace overrides wheels-only"
      fi
    fi
  else
    warn "python3 absent — cannot check /workspace for project-level wheels-only opt-outs (G10p)"
  fi
fi

echo ""
echo "== $PASS passed | $FAIL failed | $WARN warnings =="
[[ $FAIL -eq 0 ]]
