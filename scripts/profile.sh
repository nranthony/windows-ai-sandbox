#!/usr/bin/env bash
# =============================================================================
# profile.sh — multi-profile entry point for the windows-ai-sandbox stack
# =============================================================================
# Usage:
#   scripts/profile.sh <profile> <command> [extra args...]
#   scripts/profile.sh list
#   scripts/profile.sh build
#
# Commands:
#   up              start the stack for this profile (creates state dirs)
#   down            stop + remove containers (keeps persistent state). Also
#                   age-prunes MCP logs + session transcripts older than
#                   SANDBOX_LOG_RETENTION_DAYS (default 14; recent sessions
#                   stay `claude --resume`-able).
#   attach          zsh into the agent container as root
#   auth            run `claude login` inside the container
#   auth-github     run `gh auth login` inside the container
#   auth-gitlab     run `glab auth login` inside the container
#   auth-antigravity  run `agy` (Antigravity CLI) inside the container —
#                   interactive console sign-in (URL + one-time code)
#   logs            tail container logs
#   status          docker compose ps for this profile
#   build           force-rebuild the shared image (all profiles pick it up)
#   recreate-all    force-recreate EVERY running profile onto the current image
#                   (no profile arg; down profiles skipped). Use after `build`.
#   recreate        force-recreate this profile's containers (no image rebuild)
#   rebuild         build + recreate this profile's containers
#   reset-settings  overwrite this profile's claude settings.json from
#                   sandbox_templates/claude/claude-settings.json (backs up the old one)
#   reset-skills    overwrite this profile's claude skills from sandbox_templates/skills/
#                   (backs up old skill dirs)
#   db <SUB>        set this profile's DEFAULT DB sibling(s) so a plain `up`
#                   brings them up with no COMPOSE_PROFILES prefix (persisted in
#                   the profile's compose-profiles file, mirroring subnet-octet).
#                   SUB: enable <postgres|mongo|all> | disable | status.
#                   Does not touch running containers — run up/recreate to apply.
#   db-reset        wipe the postgres data volume and bring postgres back up
#                   with a fresh initdb. Flags: --yes (skip confirmation).
#   clean           prune rotating state (old .claude.json backups, paste-cache,
#                   shell-snapshots). Pass --deep to also drop MCP debug logs
#                   and settings.json.bak.* backups.
#   wipe            blank-slate this profile: down, nuke per-profile state,
#                   KEEP auth (claude creds, claude.json, gh, glab, git identity,
#                   antigravity (agy) config, db.env). Confirms first.
#                   Flags: --dry-run, --yes, --all-volumes
#   list            list all existing profiles with up/down status
#   exec <cmd...>   run arbitrary command inside the container
#   api [SUB]       manage the pipeline FastAPI (uvicorn :8001) inside the agent
#                   (detached + idempotent; targets /workspace/pipeline).
#                   SUB: up (default) | down | status | logs
#
# Optional flags (accepted by up / recreate / rebuild):
#   --expose-dev    layer docker-compose.<profile>.expose-dev.yml on top of the
#                   base compose file. Used to opt into LAN port publishing for
#                   a browser to reach a dev server inside the container.
#                   UNSAFE: may drop the `internal: true` network isolation.
#
# Environment:
#   SANDBOX_GPU     GPU overlay control (default: auto). `auto` layers
#                   docker-compose.wsl-gpu.yml when /dev/dxg exists (WSL2 with
#                   GPU paravirtualization); bare-Linux hosts come up GPU-less.
#                   Set 1 to force the overlay, 0 to suppress it.
#
# Optional flags (accepted by build / rebuild):
#   --no-cache      pass --no-cache to `docker compose build`. Forces every
#                   Dockerfile layer to re-run; pulls latest claude-code / npm
#                   packages / apt indexes instead of reusing cached layers.
#   --pull          pass --pull to `docker compose build`. Re-checks the base
#                   image registry for a newer digest (no-op for the pinned
#                   CUDA digest but future-proof).
#   --refresh-ai    bump BOTH AI CLIs (Claude Code + Antigravity agy) to latest
#                   by busting only the tail refresh layer — a fast, targeted
#                   rebuild that leaves the heavy Node/CUDA/uv/font layers cached.
#   --claude-version=X.Y.Z
#                   pin Claude Code to a specific npm version (implies
#                   --refresh-ai; agy still refreshes to latest).
#   --recreate-running  (build only) after building, force-recreate every
#                   running profile onto the new image (runs `recreate-all`).
# =============================================================================
set -euo pipefail

REPO_ROOT="${HOME}/repo"
PROFILES_ROOT="${HOME}/.ai-sandbox/profiles"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE_ARGS=()
BUILD_FLAGS=()

info()  { printf '\033[0;36m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
fail()  { printf '\033[0;31m[FAIL]\033[0m  %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,/^# =====/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

# Age-based log retention. Bounds the historical-exposure window for MCP debug
# logs and Claude session transcripts (full prompts/responses — the privacy
# "pot of gold" flagged in SECURITY_ASSESSMENT.md) WITHOUT wiping recent
# sessions: anything newer than the window stays `claude --resume`-able. This
# is deliberately age-based, not a blanket wipe like `clean --deep`. Runs
# automatically on `down`. Window configurable via SANDBOX_LOG_RETENTION_DAYS
# (default 14). Non-fatal — a prune failure must never block taking the stack
# down.
prune_logs() {
  local pdir="$1" days="${SANDBOX_LOG_RETENTION_DAYS:-14}"
  [[ -d "$pdir" ]] || return 0
  # Guard: a non-integer window (e.g. empty or "all") would make `-mtime +`
  # match nothing or everything. Bail loudly rather than risk a surprise wipe.
  [[ "$days" =~ ^[0-9]+$ ]] || { warn "SANDBOX_LOG_RETENTION_DAYS='$days' not an integer; skipping log prune"; return 0; }
  local n=0 m=0
  # MCP debug logs/transcripts.
  if [[ -d "$pdir/cache/claude-cli-nodejs" ]]; then
    n=$(find "$pdir/cache/claude-cli-nodejs" -type f -name '*.jsonl' -mtime "+$days" -print -delete 2>/dev/null | wc -l)
  fi
  # Session transcripts (full prompts/responses) + prompt history.
  if [[ -d "$pdir/claude-home/projects" ]]; then
    m=$(find "$pdir/claude-home/projects" -type f -name '*.jsonl' -mtime "+$days" -print -delete 2>/dev/null | wc -l)
  fi
  find "$pdir/claude-home" -maxdepth 1 -name 'history.jsonl' -mtime "+$days" -delete 2>/dev/null || true
  ok "log prune: removed $((n + m)) transcript/log file(s) older than ${days}d (SANDBOX_LOG_RETENTION_DAYS=${days})"
}

# ---------------------------------------------------------------------------
# ensure_state — idempotent per-profile dir bootstrap
# ---------------------------------------------------------------------------
ensure_state() {
  local p="$PROFILES_ROOT/$PROFILE"
  mkdir -p "$p/claude-home" "$p/cache" "$p/config" "$p/gemini-home"
  if [[ ! -s "$p/claude.json" ]]; then
    printf '{}\n' > "$p/claude.json"
  fi
  mkdir -p "$p/config/git"
  cp "$SCRIPT_DIR/sandbox_templates/common/db.env.template" "$p/db.env.example"
  if [[ ! -f "$p/claude-home/settings.json" ]] && [[ -f "$SCRIPT_DIR/sandbox_templates/claude/claude-settings.json" ]]; then
    cp "$SCRIPT_DIR/sandbox_templates/claude/claude-settings.json" "$p/claude-home/settings.json"
  fi
  if [[ -d "$SCRIPT_DIR/sandbox_templates/skills" ]]; then
    mkdir -p "$p/claude-home/skills"
    for skill_src in "$SCRIPT_DIR/sandbox_templates/skills"/*/; do
      [[ -d "$skill_src" ]] || continue
      name="$(basename "$skill_src")"
      if [[ ! -d "$p/claude-home/skills/$name" ]]; then
        cp -R "$skill_src" "$p/claude-home/skills/$name"
      fi
    done
  fi
  if [[ -f "$p/config/git/config" ]] && \
     grep -qE 'helper\s*=.*(vscode-server|vscode-remote-containers|git-credential-manager)' \
       "$p/config/git/config"; then
    awk '
      /^[[:space:]]*helper[[:space:]]*=.*(vscode-server|vscode-remote-containers|git-credential-manager)/ { next }
      { print }
    ' "$p/config/git/config" > "$p/config/git/config.scrubbed" \
      && mv "$p/config/git/config.scrubbed" "$p/config/git/config"
  fi
  # Git identity: seed AND enforce a noreply address on every up. This file is
  # the container's GIT_CONFIG_GLOBAL, so it governs every repo under
  # /workspace — commits authored in the sandbox must never carry a personal
  # email. GIT_USER_NAME/GIT_USER_EMAIL override the defaults, but an override
  # email that is not a users.noreply.github.com address is refused (that is
  # the whole guarantee). Mirrors init-profile-state.sh.
  local git_id_name="${GIT_USER_NAME:-nranthony}"
  local git_id_email="${GIT_USER_EMAIL:-16306836+nranthony@users.noreply.github.com}"
  if [[ "$git_id_email" != *@users.noreply.github.com ]]; then
    warn "GIT_USER_EMAIL '$git_id_email' is not a users.noreply.github.com address — using default noreply identity"
    git_id_name="nranthony"
    git_id_email="16306836+nranthony@users.noreply.github.com"
  fi
  local cur_email=""
  [[ -f "$p/config/git/config" ]] && \
    cur_email="$(git config --file "$p/config/git/config" user.email 2>/dev/null || true)"
  if [[ "$cur_email" != *@users.noreply.github.com ]]; then
    [[ -n "$cur_email" ]] && \
      warn "replacing non-noreply git user.email '$cur_email' with '$git_id_email'"
    git config --file "$p/config/git/config" user.name  "$git_id_name"
    git config --file "$p/config/git/config" user.email "$git_id_email"
  fi
  if [[ -f "$p/db.env" ]]; then
    chmod 600 "$p/db.env" 2>/dev/null || warn "could not chmod 600 $p/db.env"
  fi
}

# ---------------------------------------------------------------------------
# scrub_container_git_leaks — in-container belt for VS Code attach leakage
# ---------------------------------------------------------------------------
# ensure_state scrubs the bind-mounted /root/.config/git/config from the host,
# but VS Code's Dev Containers attach also injects a host-reaching
# credential.helper into the container ROOTFS — /etc/gitconfig (system layer,
# git reads it) and /root/.gitconfig (copyGitConfig copy) — which the host-side
# scrub can't reach. This strips only host-reaching helper lines (targeted, not
# a file wipe) from those rootfs configs via docker exec, post-up. Like
# ensure_state it is REACTIVE (cleans on up, not mid-session) — prevention is the
# host `dev.containers.gitCredentialHelperConfigLocation: none` setting. Runs
# after the container is up; no-op on a clean recreate; non-fatal.
scrub_container_git_leaks() {
  local scrubbed
  scrubbed="$(docker exec "$AGENT" sh -c '
    pat="vscode-server|vscode-remote-containers|git-credential-manager|osxkeychain"
    for f in /etc/gitconfig /root/.gitconfig; do
      [ -f "$f" ] || continue
      grep -Eq "helper[[:space:]]*=.*($pat)" "$f" 2>/dev/null || continue
      if grep -Ev "helper[[:space:]]*=.*($pat)" "$f" > "$f.scrubbed" 2>/dev/null \
         && mv "$f.scrubbed" "$f"; then
        echo "$f"
      fi
    done
  ' 2>/dev/null)" || return 0
  [[ -n "$scrubbed" ]] || return 0
  while IFS= read -r f; do
    [[ -n "$f" ]] && warn "scrubbed host-reaching credential.helper from container $f (VS Code attach leak — set host dev.containers.gitCredentialHelperConfigLocation=none to prevent)"
  done <<< "$scrubbed"
}

# ---------------------------------------------------------------------------
# Subnet allocation — give each profile its own 172.30.<octet>.0/24
# ---------------------------------------------------------------------------
# The compose file pins egress-proxy/postgres/mongo to 172.30.<octet>.10/.20/.30
# and feeds the agent the same addresses via extra_hosts (DNS is sinkholed, so
# extra_hosts is the ONLY name resolution path). All of that reads SANDBOX_OCTET,
# so the subnet and the static pins can never drift. Allocating a distinct octet
# per profile is what lets concurrent profiles coexist instead of all colliding
# on 172.30.0.0/24 ("Pool overlaps with other one on this address space").

# NOTE: deliberately written in the bash-3.2 portable subset (no associative
# arrays, no `xargs -r`, POSIX `cksum` not `md5sum`) so this allocator drops in
# verbatim to the sister macolima repo (macOS / bash 3.2). "Used octet" sets are
# carried as space-padded strings (" 0 65 187 ") tested with a case-glob, which
# is the 3.2-safe equivalent of an associative-array membership check.

# Deterministic first-choice octet (0-255) from the profile name. Stable across
# wipes; cksum is POSIX and identical-output on Linux + macOS (md5sum is not).
octet_start() { printf '%s' "$1" | cksum | awk '{print $1 % 256}'; }

# Collect octets already claimed by OTHER profiles' subnet-octet files into a
# space-padded string. Shared by both functions below.
# NOTE: uses `if` blocks, not `[[ ... ]] && continue` — the latter is a standalone
# command whose nonzero status trips `set -e` (line 56) when this runs inside
# command substitution, $(sibling_octets). `if` conditions are exempt from set -e.
sibling_octets() {
  local d name o out=" "
  for d in "$PROFILES_ROOT"/*/; do
    if [[ ! -d "$d" ]]; then continue; fi           # literal glob when no profiles
    name="$(basename "$d")"
    if [[ "$name" == "$PROFILE" ]]; then continue; fi
    if [[ ! -f "$d/subnet-octet" ]]; then continue; fi
    if ! read -r o < "$d/subnet-octet"; then continue; fi
    if [[ "$o" =~ ^[0-9]+$ ]]; then out="$out$o "; fi
  done
  printf '%s' "$out"
}

# First free octet at/after the name-hash start that is NOT in $1 (a space-padded
# "used" string). Echoes the octet, or empty if the /24 space is exhausted.
first_free_octet() {
  local used="$1" start i c
  start="$(octet_start "$PROFILE")"
  for (( i=0; i<256; i++ )); do
    c=$(( (start + i) % 256 ))
    case "$used" in *" $c "*) continue ;; esac
    printf '%s' "$c"; return
  done
}

# Cheap path (no docker calls): reuse the persisted octet, or assign one from the
# name hash, skipping octets already claimed by other profiles. Always runs;
# exports SANDBOX_OCTET.
ensure_subnet_octet() {
  local f="$PROFILES_ROOT/$PROFILE/subnet-octet" want
  if [[ -f "$f" ]] && read -r want < "$f" \
     && [[ "$want" =~ ^[0-9]+$ ]] && (( want <= 255 )); then
    export SANDBOX_OCTET="$want"; return
  fi
  want="$(first_free_octet "$(sibling_octets)")"
  [[ -n "$want" ]] || fail "no free /24 in 172.30.0.0/16 (256-profile max)"
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$want" > "$f"
  export SANDBOX_OCTET="$want"
}

# Pool check (call right before a network-creating `compose up`): if our assigned
# /24 is already held by ANOTHER docker network — a non-profile project, or a
# stale/foreign net — bump to the next free octet and rewrite the file. Skips
# our own sandbox-internal so a recreate doesn't flag itself. One docker pass;
# only invoked on up/recreate/rebuild, never on down/status/attach.
ensure_octet_free() {
  local own="${COMPOSE_PROJECT_NAME}_sandbox-internal" net sub want taken
  taken="$(sibling_octets)"
  while read -r net sub; do
    if [[ "$net" == "$own" ]]; then continue; fi
    if [[ "$sub" =~ ^172\.30\.([0-9]+)\.0/ ]]; then taken="$taken${BASH_REMATCH[1]} "; fi
  done < <(docker network ls -q 2>/dev/null \
            | while read -r id; do
                docker network inspect "$id" \
                  --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null || true
              done \
            | awk '{for (i=2;i<=NF;i++) print $1, $i}')
  case "$taken" in
    *" ${SANDBOX_OCTET} "*) ;;   # our /24 is occupied — fall through, reallocate
    *)                      return ;;   # free — keep current assignment
  esac
  want="$(first_free_octet "$taken")"
  if [[ -z "$want" ]]; then fail "no free /24 in 172.30.0.0/16 (pool check)"; fi
  mkdir -p "$PROFILES_ROOT/$PROFILE"
  printf '%s\n' "$want" > "$PROFILES_ROOT/$PROFILE/subnet-octet"
  warn "172.30.${SANDBOX_OCTET}.0/24 already in use; reassigned '$PROFILE' to 172.30.${want}.0/24"
  export SANDBOX_OCTET="$want"
}

# Persistent per-profile DB selection. Mirrors subnet-octet: one small file under
# the profile's state dir, read on every command and exported before any compose
# call, so `up`/`recreate`/`rebuild` bring the chosen DB sibling(s) up WITHOUT a
# COMPOSE_PROFILES prefix (closes the "plain up starts no Postgres" footgun).
# An explicit COMPOSE_PROFILES in the environment always wins as a one-shot
# override and is NOT persisted — set the durable default with `db enable`.
ensure_compose_profiles() {
  local f="$PROFILES_ROOT/$PROFILE/compose-profiles" want
  if [[ -n "${COMPOSE_PROFILES+x}" ]]; then return; fi   # env override — respect, don't touch the file
  if [[ -f "$f" ]] && read -r want < "$f" && [[ -n "$want" ]]; then
    export COMPOSE_PROFILES="$want"
  fi
}

# ---------------------------------------------------------------------------
# Compose overlays — base file + conditional layers
# ---------------------------------------------------------------------------
# Once ANY `-f` is passed, docker compose stops auto-loading docker-compose.yml,
# so every overlay must be layered ON TOP of an explicit base. add_overlay
# seeds the base file on first use; callers only name the layer.
add_overlay() {
  (( ${#COMPOSE_FILE_ARGS[@]} > 0 )) || COMPOSE_FILE_ARGS+=(-f docker-compose.yml)
  COMPOSE_FILE_ARGS+=(-f "$1")
}

# GPU/substrate detection. WSL2 with GPU paravirtualization exposes /dev/dxg;
# that node never exists on bare Linux, so its presence is a precise signal
# for layering the WSL GPU overlay (devices + /usr/lib/wsl + LD_LIBRARY_PATH).
# Bare-Linux hosts skip the overlay and the same compose base comes up
# GPU-less. Override auto-detection with SANDBOX_GPU=1 (force) or 0 (suppress).
add_gpu_overlay() {
  # SANDBOX_HOST_GPU is substrate metadata, independent of the SANDBOX_GPU
  # knob: the base compose passes it into the container so verify-sandbox.sh
  # can tell "correctly GPU-less (bare Linux)" apart from "WSL host whose GPU
  # overlay silently failed to layer" — a drift signal that would otherwise
  # be invisible from inside the container.
  export SANDBOX_HOST_GPU=0
  if [[ -e /dev/dxg ]]; then SANDBOX_HOST_GPU=1; fi
  # NOTE: explicit `return 0` — a bare `return` propagates the failed [[ ]]
  # test's status 1, and this function is called as a top-level statement
  # under `set -e`, which would abort every command on GPU-less hosts.
  case "${SANDBOX_GPU:-auto}" in
    0|false|no)
      [[ "$SANDBOX_HOST_GPU" == "1" ]] && warn "SANDBOX_GPU=0: host has /dev/dxg but the GPU overlay is suppressed — container will be GPU-less"
      return 0 ;;
    1|true|yes)
      [[ -e /dev/dxg ]] || warn "SANDBOX_GPU=1 forced but /dev/dxg does not exist on this host — 'up' will fail on the device mapping (the overlay is WSL2-only)" ;;
    auto)        [[ -e /dev/dxg ]] || return 0 ;;
    *) fail "SANDBOX_GPU='${SANDBOX_GPU}' invalid (use 0, 1, or auto)" ;;
  esac
  add_overlay "docker-compose.wsl-gpu.yml"
}

# ---------------------------------------------------------------------------
# parse_flags — strip --expose-dev from "$@", populate COMPOSE_FILE_ARGS
# ---------------------------------------------------------------------------
parse_flags() {
  local expose=0 remaining=()
  for a in "$@"; do
    case "$a" in
      --expose-dev) expose=1 ;;
      --no-cache|--pull) BUILD_FLAGS+=("$a") ;;
      # AI-CLI refresh (see the standalone `build` handler for rationale). Only
      # meaningful for rebuild; up/recreate reject any BUILD_FLAGS below.
      --refresh-ai)
        BUILD_FLAGS+=(--build-arg "AI_CLI_REFRESH=$(date +%s)") ;;
      --claude-version=*)
        BUILD_FLAGS+=(--build-arg "CLAUDE_VERSION=${a#*=}" \
                      --build-arg "AI_CLI_REFRESH=$(date +%s)") ;;
      *) remaining+=("$a") ;;
    esac
  done
  ARGS=("${remaining[@]+"${remaining[@]}"}")
  if [[ "$expose" == "1" ]]; then
    local override="$SCRIPT_DIR/docker-compose.$PROFILE.expose-dev.yml"
    [[ -f "$override" ]] || fail "--expose-dev: override not found: $override
       Create the override at the repo root (a YAML file adding a
       'ports:' block under ai-sandbox), then rerun."
    add_overlay "docker-compose.$PROFILE.expose-dev.yml"
    warn "UNSAFE: --expose-dev — layering $override (publishes ports to LAN)"
  fi
}

# --- `list` is the only command that doesn't take a profile arg --------------
if [[ "${1:-}" == "list" ]]; then
  if [[ ! -d "$PROFILES_ROOT" ]]; then
    echo "(no profiles yet — try: scripts/profile.sh <name> up)"
    exit 0
  fi
  echo "Profiles under $PROFILES_ROOT:"
  shopt -s nullglob
  for d in "$PROFILES_ROOT"/*/; do
    name="$(basename "$d")"
    status="down"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "ai-sandbox-$name"; then
      status="up"
    fi
    repo_dir="$REPO_ROOT/$name"
    [[ -d "$repo_dir" ]] || repo_dir="$repo_dir (MISSING)"
    printf '  %-20s %-6s %s\n' "$name" "$status" "$repo_dir"
  done
  exit 0
fi

# --- `recreate-all` — force-recreate every RUNNING profile (no profile arg) --
# Rolls all live profiles onto the current windows-ai-sandbox:latest image.
# Use after `build` to adopt a new image without a manual per-profile loop.
# Down profiles are SKIPPED — they pick up the new image on their next `up`.
# Any extra args (e.g. --expose-dev) are forwarded to each `recreate`.
if [[ "${1:-}" == "recreate-all" ]]; then
  running=()
  while IFS= read -r cname; do
    case "$cname" in ai-sandbox-*) running+=("${cname#ai-sandbox-}") ;; esac
  done < <(docker ps --format '{{.Names}}' 2>/dev/null | sort)
  if (( ${#running[@]} == 0 )); then
    warn "No running profiles (no ai-sandbox-* containers up). Nothing to recreate."
    exit 0
  fi
  info "Recreating ${#running[@]} running profile(s): ${running[*]}"
  rc=0
  for p in "${running[@]}"; do
    info "── recreate '$p' ──"
    "$0" "$p" recreate "${@:2}" || { rc=1; warn "recreate failed for '$p' (continuing)"; }
  done
  (( rc == 0 )) && ok "recreate-all done (${#running[@]} profile(s))." \
                || warn "recreate-all finished with errors — see above."
  exit "$rc"
fi

# --- global `build` (no profile needed) --------------------------------------
if [[ "${1:-}" == "build" ]]; then
  build_flags=()
  recreate_running=0
  for a in "${@:2}"; do
    case "$a" in
      --no-cache|--pull) build_flags+=("$a") ;;
      # Bust ONLY the AI-CLI refresh layer (Claude Code + agy) so a version bump
      # rebuilds just the tail, not the whole image. A changing token forces the
      # ARG AI_CLI_REFRESH RUN to re-execute and pull upstream.
      --refresh-ai)
        build_flags+=(--build-arg "AI_CLI_REFRESH=$(date +%s)") ;;
      # Pin Claude Code to a specific npm version (implies --refresh-ai).
      --claude-version=*)
        build_flags+=(--build-arg "CLAUDE_VERSION=${a#*=}" \
                      --build-arg "AI_CLI_REFRESH=$(date +%s)") ;;
      # After building, force-recreate every running profile onto the new image.
      --recreate-running) recreate_running=1 ;;
      *) fail "build: unknown flag '$a' (valid: --no-cache --pull --refresh-ai --claude-version=X.Y.Z --recreate-running)" ;;
    esac
  done
  info "Building windows-ai-sandbox:latest${build_flags[*]:+ (${build_flags[*]})}"
  cd "$SCRIPT_DIR"
  PROFILE=_build docker compose build "${build_flags[@]+"${build_flags[@]}"}" ai-sandbox
  docker image prune -f
  docker builder prune -f --keep-storage=4g
  if (( recreate_running == 1 )); then
    info "Rolling running profiles onto the new image (--recreate-running)"
    exec "$0" recreate-all
  fi
  exit 0
fi

# --- arg parsing -------------------------------------------------------------
[[ $# -ge 2 ]] || usage

PROFILE="$1"
CMD="$2"
shift 2

[[ "$PROFILE" =~ ^[a-zA-Z0-9_-]+$ ]] \
  || fail "Profile name must match [a-zA-Z0-9_-]+ (got: $PROFILE)"

export PROFILE
export COMPOSE_PROJECT_NAME="ai-sandbox-$PROFILE"
AGENT="ai-sandbox-$PROFILE"

# Resolve this profile's /24 (172.30.<SANDBOX_OCTET>.0/24) for every compose
# call below. Cheap (file read after first assignment); up-family commands
# additionally run ensure_octet_free before creating the network.
ensure_subnet_octet

# Export this profile's persisted DB selection (COMPOSE_PROFILES) for every
# compose call below, unless the caller set it explicitly. Cheap file read.
ensure_compose_profiles

# Layer the WSL2 GPU overlay when the substrate has one (see add_gpu_overlay).
# Runs before parse_flags so --expose-dev stacks on top of it.
add_gpu_overlay

cd "$SCRIPT_DIR"

ensure_repo_dir() {
  if [[ ! -d "$REPO_ROOT/$PROFILE" ]]; then
    fail "Repo dir does not exist: $REPO_ROOT/$PROFILE
      Create it first:  mkdir -p '$REPO_ROOT/$PROFILE'
      Or clone repos into it before bringing the stack up."
  fi
}

# --- dispatch ----------------------------------------------------------------
case "$CMD" in
  up)
    parse_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
    (( ${#BUILD_FLAGS[@]} == 0 )) || \
      fail "up: ${BUILD_FLAGS[*]} only applies to build/rebuild (up does not rebuild the image)"
    ensure_repo_dir
    ensure_state
    ensure_octet_free
    info "Bringing up profile '$PROFILE' (project: $COMPOSE_PROJECT_NAME, subnet: 172.30.${SANDBOX_OCTET}.0/24)"
    docker compose "${COMPOSE_FILE_ARGS[@]}" up -d "$@"
    scrub_container_git_leaks
    ok "Stack up. Attach with:  scripts/profile.sh $PROFILE attach"
    ;;

  down)
    info "Taking down profile '$PROFILE'"
    docker compose down "$@"
    prune_logs "$PROFILES_ROOT/$PROFILE"
    ok "Stack down. Persistent state preserved under $PROFILES_ROOT/$PROFILE/"
    ;;

  attach)
    info "Attaching to $AGENT (Ctrl-D to exit)"
    exec docker exec -it "$AGENT" zsh
    ;;

  auth)
    info "Running 'claude login' inside $AGENT"
    exec docker exec -it "$AGENT" claude login
    ;;

  auth-github)
    info "Running 'gh auth login' inside $AGENT"
    exec docker exec -it "$AGENT" gh auth login
    ;;

  auth-gitlab)
    info "Running 'glab auth login' inside $AGENT"
    exec docker exec -it "$AGENT" glab auth login
    ;;

  auth-antigravity)
    info "Running 'agy' inside $AGENT (interactive Antigravity sign-in)"
    exec docker exec -it "$AGENT" agy
    ;;

  api)
    # Manage the pipeline FastAPI (uvicorn :8001) inside the agent. Detached +
    # idempotent so the API survives the launching shell and is easy to (re)start
    # after a container restart. Pipeline-specific: targets
    # /workspace/pipeline/.venv-linux. Subcommands: up (default)|down|status|logs.
    # Idempotency keys on the live :8001 health endpoint — NOT pgrep, which would
    # self-match this launcher's own command line.
    sub="${1:-up}"
    case "$sub" in
      up)
        info "Pipeline API up (uvicorn :8001) in $AGENT (idempotent)"
        docker exec "$AGENT" bash -c '
          if curl -fsS --noproxy "*" -o /dev/null http://127.0.0.1:8001/admin/ready 2>/dev/null; then
            echo "already serving on :8001"; exit 0
          fi
          cd /workspace/pipeline 2>/dev/null || { echo "no /workspace/pipeline"; exit 1; }
          [ -x .venv-linux/bin/uvicorn ] || { echo "no .venv-linux — install pipeline deps first"; exit 1; }
          setsid bash -c "PIPELINE_DATA_DIR=data/dev .venv-linux/bin/uvicorn pipeline.api:create_app --factory --host 0.0.0.0 --port 8001 --workers 1 > /workspace/pipeline/uvicorn.log 2>&1" </dev/null &
          echo "launched"
        '
        ;;
      down)
        info "Pipeline API down in $AGENT"
        docker exec "$AGENT" pkill -f "uvicorn pipeline.api" 2>/dev/null && info "stopped" || warn "not running"
        ;;
      status)
        exec docker exec "$AGENT" bash -c '
          if curl -fsS --noproxy "*" http://127.0.0.1:8001/admin/ready 2>/dev/null; then
            echo; pgrep -af "[u]vicorn pipeline.api" || true
          else
            echo "not running (:8001 not responding)"; exit 1
          fi'
        ;;
      logs)
        exec docker exec "$AGENT" tail -n 40 -f /workspace/pipeline/uvicorn.log
        ;;
      *)
        fail "api: unknown subcommand '$sub' (use: up | down | status | logs)"
        ;;
    esac
    ;;

  logs)
    exec docker compose logs -f "$@"
    ;;

  status|ps)
    exec docker compose ps "$@"
    ;;

  recreate)
    parse_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
    (( ${#BUILD_FLAGS[@]} == 0 )) || \
      fail "recreate: ${BUILD_FLAGS[*]} only applies to build/rebuild (recreate does not rebuild the image)"
    ensure_repo_dir
    ensure_state
    ensure_octet_free
    info "Force-recreating profile '$PROFILE'"
    docker compose "${COMPOSE_FILE_ARGS[@]}" up -d --force-recreate "$@"
    scrub_container_git_leaks
    ;;

  rebuild)
    parse_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
    ensure_repo_dir
    ensure_state
    info "Rebuilding image + recreating profile '$PROFILE'${BUILD_FLAGS[*]:+ (${BUILD_FLAGS[*]})}"
    docker compose build "${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}" ai-sandbox
    docker image prune -f
    docker builder prune -f --keep-storage=4g
    ensure_octet_free
    docker compose "${COMPOSE_FILE_ARGS[@]}" up -d --force-recreate
    scrub_container_git_leaks
    ;;

  exec)
    [[ $# -ge 1 ]] || fail "Usage: scripts/profile.sh $PROFILE exec <cmd> [args...]"
    exec docker exec -it "$AGENT" "$@"
    ;;

  verify)
    src="$SCRIPT_DIR/scripts/verify-sandbox.sh"
    [[ -f "$src" ]] || fail "verify-sandbox.sh missing: $src"
    info "Running verify-sandbox.sh inside $AGENT (streamed via stdin)"
    exec docker exec -i "$AGENT" bash -s -- "$@" < "$src"
    ;;

  audit)
    flag=""
    for a in "$@"; do
      case "$a" in
        --stage-only|--clean|--compact) flag="$a" ;;
      esac
    done

    if [[ "$flag" == "--clean" ]]; then
      exec bash "$SCRIPT_DIR/scripts/stage-audit-package.sh" "$PROFILE" --clean
    fi

    info "Staging audit package for '$PROFILE'"
    bash "$SCRIPT_DIR/scripts/stage-audit-package.sh" "$PROFILE"

    if [[ "$flag" == "--stage-only" ]]; then
      ok "Stage complete. Run audit with:  scripts/profile.sh $PROFILE audit"
      exit 0
    fi

    stamp=$(date -u +%Y-%m-%dT%H-%M-%SZ)
    audits_host="$PROFILES_ROOT/$PROFILE/claude-home/audits"
    mkdir -p "$audits_host"
    json_host="$audits_host/$stamp-$PROFILE-audit.json"

    info "Running audit inside $AGENT → $json_host"
    pretty_flag=""
    [[ "$flag" == "--compact" ]] && pretty_flag="--compact"
    if docker exec "$AGENT" bash /workspace/temp_audit_package/scripts/audit/audit.sh $pretty_flag > "$json_host"; then
      ok "Audit JSON saved: $json_host"
      ok "Container path:   /root/.claude/audits/$stamp-$PROFILE-audit.json"
      if command -v jq >/dev/null 2>&1; then
        info "Summary: $(jq -c .summary "$json_host")"
      fi
    else
      fail "Audit run failed; partial JSON at $json_host"
    fi
    ;;

  reset-settings)
    src="$SCRIPT_DIR/sandbox_templates/claude/claude-settings.json"
    dst="$PROFILES_ROOT/$PROFILE/claude-home/settings.json"
    [[ -f "$src" ]] || fail "template missing: $src"
    mkdir -p "$(dirname "$dst")"
    if [[ -f "$dst" ]]; then
      backup="$dst.bak.$(date +%Y%m%d-%H%M%S)"
      cp "$dst" "$backup"
      info "backed up existing settings → $backup"
    fi
    cp "$src" "$dst"
    ok "settings.json reset for '$PROFILE'. Restart claude inside the container to pick up."
    ;;

  reset-skills)
    src_dir="$SCRIPT_DIR/sandbox_templates/skills"
    dst_dir="$PROFILES_ROOT/$PROFILE/claude-home/skills"
    [[ -d "$src_dir" ]] || fail "no skills templates: $src_dir"
    mkdir -p "$dst_dir"
    stamp="$(date +%Y%m%d-%H%M%S)"
    for skill_src in "$src_dir"/*/; do
      [[ -d "$skill_src" ]] || continue
      name="$(basename "$skill_src")"
      if [[ -d "$dst_dir/$name" ]]; then
        backup="$dst_dir/$name.bak.$stamp"
        mv "$dst_dir/$name" "$backup"
        info "backed up existing skill → $backup"
      fi
      cp -R "$skill_src" "$dst_dir/$name"
      ok "skill '$name' reset for '$PROFILE'"
    done
    ok "all skills reset. Restart claude inside the container to pick up."
    ;;

  db)
    # Manage this profile's DEFAULT DB siblings. Writes the persisted
    # compose-profiles file (mirroring subnet-octet) that ensure_compose_profiles
    # reads into COMPOSE_PROFILES on every command — so once enabled, a plain
    # `up` brings the DB up with no env-var prefix. Does not touch running
    # containers; run `up`/`recreate` afterwards to apply.
    f="$PROFILES_ROOT/$PROFILE/compose-profiles"
    sub="${1:-status}"
    case "$sub" in
      enable)
        case "${2:-}" in
          postgres) sel=db-postgres ;;
          mongo)    sel=db-mongo ;;
          all)      sel=db-all ;;
          "")       fail "db enable: which? (postgres | mongo | all)" ;;
          *)        fail "db enable: unknown target '${2}' (valid: postgres | mongo | all)" ;;
        esac
        mkdir -p "$PROFILES_ROOT/$PROFILE"
        printf '%s\n' "$sel" > "$f"
        ok "profile '$PROFILE' default DB set to '$sel'"
        info "apply it now:  scripts/profile.sh $PROFILE up   (or recreate, if already up)"
        ;;
      disable)
        if [[ -f "$f" ]]; then
          rm -f "$f"
          ok "profile '$PROFILE' DB default cleared — 'up' now brings agent + proxy only"
          info "stop a running DB sibling with:  scripts/profile.sh $PROFILE recreate"
        else
          info "profile '$PROFILE' had no DB default set (nothing to clear)"
        fi
        ;;
      status)
        if [[ -n "${COMPOSE_PROFILES+x}" ]]; then
          info "COMPOSE_PROFILES='${COMPOSE_PROFILES}' set in environment (one-shot override; not persisted)"
        fi
        if [[ -f "$f" ]] && read -r cur < "$f" && [[ -n "$cur" ]]; then
          ok "profile '$PROFILE' default DB: $cur"
        else
          info "profile '$PROFILE' has no default DB (plain 'up' = agent + proxy only)"
        fi
        ;;
      *) fail "db: unknown subcommand '$sub' (valid: enable <postgres|mongo|all> | disable | status)" ;;
    esac
    ;;

  db-reset)
    PG_CONTAINER="postgres-$PROFILE"
    PG_VOLUME="${COMPOSE_PROJECT_NAME}_postgres-data"

    assume_yes=0
    for a in "$@"; do
      case "$a" in
        --yes|-y) assume_yes=1 ;;
        *) fail "db-reset: unknown flag '$a' (valid: --yes)" ;;
      esac
    done

    warn "This will DESTROY all Postgres data for profile '$PROFILE':"
    warn "  volume: $PG_VOLUME"
    warn "  container: $PG_CONTAINER (will be stopped + removed + recreated)"
    warn "After reset, only the default 'postgres' database will exist."
    warn "You'll need to CREATE DATABASE for each project and re-seed."

    if [[ "$assume_yes" != "1" ]]; then
      printf '\nProceed? type the profile name (%s) to confirm: ' "$PROFILE"
      read -r confirm
      [[ "$confirm" == "$PROFILE" ]] || fail "confirmation mismatch; aborting"
    fi

    if docker ps -a --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
      info "stopping $PG_CONTAINER"
      docker stop "$PG_CONTAINER" 2>/dev/null || true
      docker rm "$PG_CONTAINER" 2>/dev/null || true
      ok "removed $PG_CONTAINER"
    else
      info "$PG_CONTAINER not found (already removed or never started)"
    fi

    if docker volume ls -q | grep -qx "$PG_VOLUME"; then
      docker volume rm "$PG_VOLUME"
      ok "removed volume $PG_VOLUME"
    else
      info "volume $PG_VOLUME not found (already removed)"
    fi

    info "bringing postgres back up (COMPOSE_PROFILES=db-postgres)"
    COMPOSE_PROFILES=db-postgres docker compose "${COMPOSE_FILE_ARGS[@]}" up -d postgres
    ok "postgres is up with a fresh data volume"

    info "waiting for postgres to accept connections..."
    for i in $(seq 1 15); do
      if docker exec "$PG_CONTAINER" pg_isready -U agent -d postgres >/dev/null 2>&1; then
        ok "postgres is ready"
        break
      fi
      [[ "$i" -eq 15 ]] && warn "postgres not ready after 15s — check: docker logs $PG_CONTAINER"
      sleep 1
    done

    echo ""
    info "Next steps — create your project databases:"
    echo "  docker exec $PG_CONTAINER psql -U agent -d postgres \\"
    echo "    -c 'CREATE DATABASE <name> OWNER agent;'"
    echo ""
    info "Then force-recreate the agent if you changed DSNs in db.env:"
    if [[ "${COMPOSE_PROFILES:-}" == db-* ]]; then
      echo "  scripts/profile.sh $PROFILE recreate   (db default already set for this profile)"
    else
      echo "  COMPOSE_PROFILES=db-postgres scripts/profile.sh $PROFILE recreate"
      echo "  (make it the default so plain 'up' includes Postgres:  scripts/profile.sh $PROFILE db enable postgres)"
    fi
    ;;

  wipe)
    dry=0; assume_yes=0; all_vols=0
    for a in "$@"; do
      case "$a" in
        --dry-run)     dry=1 ;;
        --yes|-y)      assume_yes=1 ;;
        --all-volumes) all_vols=1 ;;
        *) fail "wipe: unknown flag '$a' (valid: --dry-run --yes --all-volumes)" ;;
      esac
    done

    p="$PROFILES_ROOT/$PROFILE"
    [[ -d "$p" ]] || fail "no state dir to wipe: $p"

    shopt -s nullglob
    orphans=( "$PROFILES_ROOT"/.wipe-stage-"$PROFILE"-* )
    shopt -u nullglob
    if (( ${#orphans[@]} > 0 )); then
      warn "found orphaned wipe stage dir(s) from a previous interrupted run:"
      printf '  %s\n' "${orphans[@]}"
      fail "inspect/restore manually (creds may be inside), then rerun"
    fi

    info "wipe plan for profile '$PROFILE' (project: $COMPOSE_PROJECT_NAME)"
    echo "  PRESERVE:"
    echo "    $p/claude.json"
    echo "    $p/claude-home/.credentials.json"
    echo "    $p/config/gh/"
    echo "    $p/config/glab-cli/"
    echo "    $p/config/git/"
    echo "    $p/gemini-home/oauth_creds.json"
    echo "    $p/db.env  (if present)"
    echo "  WIPE:"
    echo "    docker compose down --remove-orphans  ($([[ $all_vols == 1 ]] && echo '+ ALL named volumes' || echo '+ DB volumes preserved'))"
    echo "    rm -rf $p/*  (everything except the PRESERVE list above)"
    echo "  AFTER:"
    echo "    re-seed claude settings.json + skills from sandbox_templates/ (via ensure_state)"
    echo "    next step: scripts/profile.sh $PROFILE up"

    if [[ "$dry" == "1" ]]; then
      ok "dry-run; no changes made"
      exit 0
    fi

    if [[ "$assume_yes" != "1" ]]; then
      printf '\nProceed? type the profile name (%s) to confirm: ' "$PROFILE"
      read -r confirm
      [[ "$confirm" == "$PROFILE" ]] || fail "confirmation mismatch; aborting"
    fi

    info "tearing down containers (including db siblings via --profile db-all)"
    if [[ "$all_vols" == "1" ]]; then
      docker compose --profile db-all down -v --remove-orphans \
        || warn "compose down had errors; continuing"
    else
      docker compose --profile db-all down --remove-orphans \
        || warn "compose down had errors; continuing"
    fi

    leftover=$(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME")
    if [[ -n "$leftover" ]]; then
      warn "containers still present after down:"
      docker ps -a --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" \
        --format '  {{.Names}}  ({{.Status}})'
      fail "refusing to continue; tear them down manually (docker rm -f <name>) and rerun"
    fi

    stage="$PROFILES_ROOT/.wipe-stage-$PROFILE-$(date +%s)"
    mkdir -p "$stage/claude-home" "$stage/config" "$stage/gemini-home"
    [[ -f "$p/claude.json" ]]                   && mv "$p/claude.json"                   "$stage/claude.json"
    [[ -f "$p/claude-home/.credentials.json" ]] && mv "$p/claude-home/.credentials.json" "$stage/claude-home/.credentials.json"
    [[ -d "$p/config/gh" ]]                     && mv "$p/config/gh"                     "$stage/config/gh"
    [[ -d "$p/config/glab-cli" ]]               && mv "$p/config/glab-cli"               "$stage/config/glab-cli"
    [[ -d "$p/config/git" ]]                    && mv "$p/config/git"                    "$stage/config/git"
    [[ -f "$p/gemini-home/oauth_creds.json" ]]  && mv "$p/gemini-home/oauth_creds.json"  "$stage/gemini-home/oauth_creds.json"
    [[ -f "$p/db.env" ]]                        && mv "$p/db.env"                        "$stage/db.env"
    ok "staged auth artefacts → $stage"

    rm -rf "$p"
    ok "removed $p"

    mkdir -p "$p/claude-home" "$p/config" "$p/gemini-home"
    [[ -f "$stage/claude.json" ]]                   && mv "$stage/claude.json"                   "$p/claude.json"
    [[ -f "$stage/claude-home/.credentials.json" ]] && mv "$stage/claude-home/.credentials.json" "$p/claude-home/.credentials.json"
    [[ -d "$stage/config/gh" ]]                     && mv "$stage/config/gh"                     "$p/config/gh"
    [[ -d "$stage/config/glab-cli" ]]               && mv "$stage/config/glab-cli"               "$p/config/glab-cli"
    [[ -d "$stage/config/git" ]]                    && mv "$stage/config/git"                    "$p/config/git"
    [[ -f "$stage/gemini-home/oauth_creds.json" ]]  && mv "$stage/gemini-home/oauth_creds.json"  "$p/gemini-home/oauth_creds.json"
    [[ -f "$stage/db.env" ]]                        && mv "$stage/db.env"                        "$p/db.env"

    residue=$(find "$stage" -mindepth 1 -not -type d 2>/dev/null)
    if [[ -n "$residue" ]]; then
      warn "unexpected files left in stage dir; not removing automatically:"
      printf '  %s\n' $residue
      warn "inspect: $stage"
    else
      rm -rf "$stage"
    fi

    [[ -f "$p/claude-home/.credentials.json" ]] && chmod 600 "$p/claude-home/.credentials.json"
    [[ -f "$p/db.env" ]]                        && chmod 600 "$p/db.env"
    ok "restored auth artefacts into fresh $p"

    ensure_state
    ok "re-seeded settings + skills from sandbox_templates/"
    ok "wipe done for '$PROFILE'. Next: scripts/profile.sh $PROFILE up"
    ;;

  clean)
    deep=0
    for a in "$@"; do [[ "$a" == "--deep" ]] && deep=1; done
    p="$PROFILES_ROOT/$PROFILE"
    [[ -d "$p" ]] || fail "no state dir: $p"

    info "cleaning $p (deep=$deep)"

    bdir="$p/claude-home/backups"
    if [[ -d "$bdir" ]]; then
      # shellcheck disable=SC2012
      ls -t "$bdir"/.claude.json.backup.* 2>/dev/null | tail -n +2 | xargs -r rm -f
      rm -f "$bdir"/.claude.json.corrupted.* 2>/dev/null || true
      ok "pruned $bdir (kept newest .claude.json.backup)"
    fi

    rm -rf "$p/claude-home/paste-cache" "$p/claude-home/shell-snapshots" 2>/dev/null || true
    mkdir -p "$p/claude-home/paste-cache" "$p/claude-home/shell-snapshots"
    ok "reset paste-cache + shell-snapshots"

    if [[ "$deep" == "1" ]]; then
      find "$p/cache/claude-cli-nodejs" -type f -name '*.jsonl' -delete 2>/dev/null || true
      ok "dropped MCP debug logs under cache/claude-cli-nodejs"
      find "$p/claude-home" -maxdepth 1 -name 'settings.json.bak.*' -delete 2>/dev/null || true
      ok "dropped settings.json.bak.* backups"
    else
      info "skip --deep targets (MCP logs, settings.json.bak.*) — pass --deep to include"
    fi

    ok "clean done for '$PROFILE'"
    ;;

  *)
    printf '\033[0;31m[FAIL]\033[0m  Unknown profile.sh command: %q\n' "$CMD" >&2
    if [[ "$CMD" == --* ]]; then
      printf '       Hint: profile.sh uses subcommands (no leading "--").\n' >&2
      printf '       Did you mean:  scripts/profile.sh %s %s\n' \
             "$PROFILE" "${CMD#--}" >&2
    fi
    echo >&2
    usage
    ;;
esac
