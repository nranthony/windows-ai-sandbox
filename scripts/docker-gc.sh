#!/usr/bin/env bash
# =============================================================================
# docker-gc.sh — reclaim Docker disk that no profile's lifecycle owns
# =============================================================================
# Usage:
#   scripts/docker-gc.sh [--dry-run] [--yes] [--days N] [--keep-cache SIZE]
#
# Examples:
#   scripts/docker-gc.sh --dry-run          # show what would go, change nothing
#   scripts/docker-gc.sh                    # show, then confirm interactively
#   scripts/docker-gc.sh --yes --days 60    # unattended, 60-day grace
#
# WHY THIS EXISTS
#   `profile.sh down` removes a profile's own containers, so sandbox state never
#   accumulates. What DOES accumulate is everything else on the same rootless
#   daemon: VS Code devcontainers (VS Code *stops* them on window close, it does
#   not remove them, so one lingers per rebuild), one-off `docker run` shells,
#   and BuildKit cache. Each stopped container keeps its writable layer — the
#   copy-on-write scratch holding pip/apt/HF caches — and nothing ever reports
#   it. Six stale devcontainers had reached 149GB before this script existed.
#
# WHAT IT REMOVES (safe under the state-placement policy in AGENTS.md: nothing
# you care about lives in a writable layer or in build cache)
#   - stopped containers older than --days (default 30)
#   - BuildKit cache above --keep-cache (default 4g)
#
# WHAT IT ONLY REPORTS, NEVER REMOVES
#   - dangling images: an unfiltered `docker image prune` also reaps the
#     digest-pinned postgres/mongo/squid, because pulling `repo:tag@sha256:...`
#     stores the image with NO tag and Docker therefore calls it dangling.
#     Auto-pruning images is the bug this policy exists to prevent.
#   - volumes with zero links: the ONLY place durable data lives. No prune
#     command here will ever touch a volume; orphans are surfaced for a human.
#
# WHAT IT NEVER TOUCHES
#   Sandbox-managed containers (compose project `ai-sandbox-*`), running or
#   stopped. scripts/profile.sh is the single lifecycle entry point for those
#   (AGENTS.md golden rule 1); a stopped one means a profile is merely `down`
#   and must stay resumable. Reaping them here would bypass profile.sh.
# =============================================================================
set -euo pipefail

info() { printf '\033[0;36m[INFO]\033[0m  %s\n' "$*"; }
ok()   { printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
fail() { printf '\033[0;31m[FAIL]\033[0m  %s\n' "$*" >&2; exit 1; }

dry=0; assume_yes=0; days=30; keep_cache=4g
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n)  dry=1 ;;
    --yes|-y)      assume_yes=1 ;;
    --days)        days="${2:?--days needs a value}"; shift ;;
    --keep-cache)  keep_cache="${2:?--keep-cache needs a value}"; shift ;;
    -h|--help)     sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" \
                     | grep '^#' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown flag '$1' (valid: --dry-run --yes --days N --keep-cache SIZE)" ;;
  esac
  shift
done
[[ "$days" =~ ^[0-9]+$ ]] || fail "--days must be an integer (got '$days')"

command -v docker >/dev/null 2>&1 || fail "docker not found on PATH"

# RFC3339 -> epoch. GNU first, then BSD/macOS (keeps this portable to the
# sibling macolima repo). On an unparseable stamp return "now", so a container
# we cannot age is treated as NEW and kept — never deleted by accident.
epoch_of() {
  local s="$1"
  date -d "$s" +%s 2>/dev/null && return 0
  date -j -f '%Y-%m-%dT%H:%M:%S' "${s%.*}" +%s 2>/dev/null && return 0
  date +%s
}

now="$(date +%s)"
cutoff=$(( now - days * 86400 ))

info "Docker GC — removing stopped containers older than ${days}d, build cache above ${keep_cache}"
echo

# ---- 1. stopped containers --------------------------------------------------
victims=(); skipped_young=0; skipped_sandbox=0
while IFS=$'\t' read -r name project; do
  [ -n "$name" ] || continue
  case "$project" in
    ai-sandbox-*) skipped_sandbox=$((skipped_sandbox + 1)); continue ;;
  esac
  fin="$(docker inspect "$name" --format '{{.State.FinishedAt}}' 2>/dev/null || echo '')"
  [ -n "$fin" ] || continue
  if [ "$(epoch_of "$fin")" -lt "$cutoff" ]; then
    victims+=("$name")
  else
    skipped_young=$((skipped_young + 1))
  fi
done < <(docker ps -a --filter status=exited --filter status=created \
           --format '{{.Names}}	{{.Label "com.docker.compose.project"}}')

if [ ${#victims[@]} -eq 0 ]; then
  ok "no stopped containers older than ${days}d"
else
  info "stopped containers to remove (${#victims[@]}):"
  for v in "${victims[@]}"; do
    printf '    %-24s %-18s %s\n' "$v" \
      "$(docker ps -a --filter "name=^${v}$" --format '{{.Size}}')" \
      "$(docker ps -a --filter "name=^${v}$" --format '{{.Status}}')"
  done
fi
(( skipped_sandbox > 0 )) && info "skipped $skipped_sandbox sandbox-managed container(s) — profile.sh owns those"
(( skipped_young   > 0 )) && info "skipped $skipped_young container(s) newer than ${days}d"
echo

# ---- 2. report-only: dangling images ----------------------------------------
dangling="$(docker images --filter dangling=true --format '{{.ID}} {{.Repository}} {{.Size}}' 2>/dev/null || true)"
if [ -n "$dangling" ]; then
  warn "dangling images present — NOT removed (may be digest-pinned deps, see header):"
  printf '%s\n' "$dangling" | sed 's/^/    /'
  info "review, then remove individually:  docker image rm <id>"
  echo
fi

# ---- 3. report-only: orphaned volumes ---------------------------------------
orphans="$(docker volume ls -q -f dangling=true 2>/dev/null || true)"
if [ -n "$orphans" ]; then
  warn "volumes with no container — NOT removed (durable data lives here):"
  printf '%s\n' "$orphans" | sed 's/^/    /'
  info "inspect before acting:  docker run --rm -v <vol>:/v:ro alpine ls -la /v"
  echo
fi

# ---- 4. execute -------------------------------------------------------------
if [ "$dry" = "1" ]; then
  ok "dry-run; no changes made"
  exit 0
fi

if [ ${#victims[@]} -eq 0 ]; then
  info "nothing to remove; reclaiming build cache only"
elif [ "$assume_yes" != "1" ]; then
  printf '\nRemove %d container(s) and their writable layers? [y/N]: ' "${#victims[@]}"
  read -r confirm
  case "$confirm" in
    y|Y|yes|YES) ;;
    *) fail "aborted; no changes made" ;;
  esac
fi

if [ ${#victims[@]} -gt 0 ]; then
  docker rm "${victims[@]}" >/dev/null || warn "some containers failed to remove; continuing"
  ok "removed ${#victims[@]} stopped container(s)"
fi

docker builder prune -f --keep-storage="$keep_cache" >/dev/null 2>&1 \
  || warn "builder prune had errors; continuing"
ok "build cache trimmed to ${keep_cache}"

echo
docker system df
