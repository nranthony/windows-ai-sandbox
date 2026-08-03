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
#   health          cross-profile consistency check (no profile arg): flags any
#                   profile whose agent / egress-proxy / configured DB siblings
#                   aren't all up together (or all down). Read-only; exit 1 if
#                   any profile is DEGRADED.
#   deps            dependency-supply-chain posture for this profile's workspace
#                   (scripts/depaudit.py). Runs HOST-SIDE and read-only: it
#                   parses lockfiles, never installs or resolves. Scans the
#                   workspace root AND each child repo that has a manifest,
#                   since a workspace holds many repos.
#                   Flags: --osv (also cross-check every lockfile-pinned package
#                   against OSV for malicious-package records; needs host
#                   network, adds no profile egress) | --json | --strict (exit 1
#                   on FAIL as well as WARN) | --quiet (never exit non-zero)
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

# Container-side allowlist path. MUST agree with the mount target in
# docker-compose.yml and the acl path in proxy/squid.conf.
# `bash scripts/with-egress.test.sh` locks all of them together — a silent
# mismatch here does not error, it makes the checks below read an empty result
# and pass, which is the failure mode that hides drift rather than reporting it.
PROXY_ALLOWLIST="/etc/squid/host/allowed_domains.txt"

# Allow-direction canary for the enforcement probe. Must be a domain the repo
# keeps permanently uncommented under ALWAYS ON — it is the one host the probe
# expects squid NOT to deny, which catches "the proxy is enforcing some other
# list entirely" (a case the deny sweep cannot see). Unlike the deny sweep, this
# costs one real upstream connect per verify.
ALLOWLIST_CANARY="api.anthropic.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE_ARGS=()
BUILD_FLAGS=()

# Scopes the post-build image prune to images WE built (LABEL in Dockerfile).
# An unfiltered `docker image prune` is daemon-wide and reaps every untagged
# image — which includes the digest-pinned postgres/mongo/squid, because a
# `repo:tag@sha256:...` pull is stored under its digest with no tag and is
# therefore "dangling". That silently re-downloaded ~660MB per build and also
# deleted unrelated projects' images on the same rootless daemon.
IMAGE_PRUNE_FILTER=(--filter label=sandbox.image=windows-ai-sandbox)

info()  { printf '\033[0;36m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
fail()  { printf '\033[0;31m[FAIL]\033[0m  %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# list_denied_domains <allowlist> — the domains this repo means to DENY.
#
# Feeds the enforcement probe below, which asks squid whether it agrees. Getting
# this set wrong is the one way the probe can cry wolf, so both traps are
# handled here rather than in the caller:
#
#   1. Commented DOMAIN lines look like `# example.com`; PLANNING-MODE section
#      HEADERS look like `# # --- Name [tag] ---` (double-commented so
#      with-egress.sh can find them). Prose comments are everywhere. Only a
#      single dotted token after `# ` is treated as a domain, which excludes
#      headers (next char is `#`) and prose (spaces).
#
#   2. A domain can be commented in ONE block and live in another — e.g.
#      github.com is commented under [quarto-install] and active under [git].
#      Probing it would report "proxy permits what the repo denies" on a
#      perfectly healthy profile. So the denied set is commented MINUS active,
#      with squid's leading-dot wildcard normalised away on both sides.
#
#   3. Squid's `dstdomain .foo.com` matches foo.com AND every subdomain, so an
#      ACTIVE wildcard also permits any commented host beneath it. Such a host
#      is not actually denied; probing it would be trap 2 one level down.
#      Commented hosts covered by an active wildcard are dropped too.
# ---------------------------------------------------------------------------
list_denied_domains() {
  local allowlist="$1" commented active wild d
  commented=$(sed -n 's/^#[[:space:]]\{1,\}\(\.\{0,1\}[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z][A-Za-z]\{1,\}\)[[:space:]]*$/\1/p' \
    "$allowlist" | sed 's/^\.//' | sort -u)
  active=$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$allowlist" \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort -u)
  # Active wildcard parents, dot retained: `.foo.com` -> suffix test `*.foo.com`.
  wild=$(printf '%s\n' "$active" | grep '^\.' || true)

  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    local covered=0 w
    while IFS= read -r w; do
      [[ -n "$w" ]] || continue
      [[ "$d" == *"$w" ]] && { covered=1; break; }
    done <<< "$wild"
    [[ "$covered" -eq 0 ]] && printf '%s\n' "$d"
  done < <(comm -23 <(printf '%s\n' "$commented") \
                    <(printf '%s\n' "$active" | sed 's/^\.//' | sort -u))
}

# ---------------------------------------------------------------------------
# check_allowlist_sync — tier-1 tripwire: is the proxy ENFORCING the repo's
# allowlist? (work/0001-dependency-guardrails T24, gap G9.)
#
# Two independent staleness modes, and a naive file comparison catches only one:
#
#   Mode B — inode swap. An atomic-replace edit (vim, sed -i, git checkout, the
#     Edit tool) gives the host file a NEW inode; the bind-mounted container
#     stays on the OLD one and can never see another update. Caught below by
#     diffing host content against the container's view. `squid -k reconfigure`
#     does NOT fix this and does not report failure — it exits 0 having applied
#     nothing. Only a restart re-resolves the mount.
#
#   Mode A — edited in place but never reloaded. The container's file is
#     byte-identical to the repo's, so the diff is clean, but squid parsed the
#     allowlist into memory at startup and is still enforcing the OLD set. This
#     is INVISIBLE to any file comparison, and no timestamp settles it either
#     (see the probe at the end of this function for why). Squid is asked
#     directly instead.
#
# The deny sweep makes no outbound request: squid answers 403 from its parsed
# config before touching DNS or an upstream, so tier 1 still works with egress
# down. Only the single allowed canary opens a real connection.
# An extra domain in the container is the dangerous direction — a host the repo
# revoked but the proxy still permits — so that is a hard FAIL, not a warning.
# ---------------------------------------------------------------------------
check_allowlist_sync() {
  local proxy="egress-proxy-$PROFILE"
  local allowlist="$SCRIPT_DIR/proxy/allowed_domains.txt"
  local rc=0

  [[ -f "$allowlist" ]] || { warn "allowlist missing: $allowlist"; return 0; }
  docker inspect "$proxy" >/dev/null 2>&1 || { info "allowlist sync: $proxy not running — skipped"; return 0; }

  local strip='^[[:space:]]*#|^[[:space:]]*$'
  local host_doms ctr_doms delta
  host_doms=$(grep -vE "$strip" "$allowlist" | sort)
  ctr_doms=$(docker exec "$proxy" sh -c \
    "grep -vE '^[[:space:]]*#|^[[:space:]]*\$' $PROXY_ALLOWLIST | sort" 2>/dev/null) || {
      warn "allowlist sync: could not read $PROXY_ALLOWLIST inside $proxy — if this profile predates the directory mount, recreate it with 'profile.sh $PROFILE up'"
      HOST_WARNS=$(( ${HOST_WARNS:-0} + 1 )); return 0; }

  if [[ "$host_doms" == "$ctr_doms" ]]; then
    ok "allowlist in sync with $proxy ($(printf '%s\n' "$host_doms" | grep -c . ) domains)"
  else
    delta=$(diff <(printf '%s\n' "$host_doms") <(printf '%s\n' "$ctr_doms") | grep '^[<>]' | head -10)
    printf '\033[0;31m[FAIL]\033[0m  allowlist DRIFT — %s is not serving this repo'"'"'s allowlist\n' "$proxy" >&2
    printf '%s\n' "$delta" | sed 's/^>/        proxy permits (repo does NOT):/; s/^</        repo has (proxy lacks):     /' >&2
    printf '        fix: docker restart %s   (or `squid -k reconfigure`, which is\n' "$proxy" >&2
    printf '        trustworthy again under the directory mount — it can no longer\n' >&2
    printf '        silently re-read a stale copy)\n' >&2
    rc=1
    HOST_FAILS=$(( ${HOST_FAILS:-0} + 1 ))
  fi

  # REGRESSION LOCK, not a live tripwire any more.
  #
  # The allowlist is now mounted as a DIRECTORY (docker-compose.yml), so the path
  # resolves on every open() and the container always sees the current inode.
  # This check should therefore never fire. It is kept precisely because it
  # cannot fire: if anyone reverts proxy/ to a single-FILE bind mount, the whole
  # silent-blindness class comes back, and this is what says so out loud.
  #
  # What it used to catch: a file mount pins an inode at container start, so any
  # host-side REPLACE — `git checkout`/`merge`/`pull`/`stash`, an editor's atomic
  # save, `sed -i`, mktemp+mv — left the container on the old, deleted inode,
  # unable to see host writes at all, with `squid -k reconfigure` re-reading the
  # stale copy and exiting 0. The content diff above could not catch it alone:
  # when only comment lines changed, the stripped domain lists still matched and
  # it reported "in sync" while the proxy was blind. MEASURED 2026-08-03 — a
  # merge left two proxies on inode 275834 against a host file of 81188.
  local host_ino ctr_ino
  host_ino=$(stat -c %i "$allowlist" 2>/dev/null || echo "")
  ctr_ino=$(docker exec -u proxy "$proxy" stat -c %i "$PROXY_ALLOWLIST" 2>/dev/null || echo "")
  if [[ -n "$host_ino" && -n "$ctr_ino" && "$host_ino" != "$ctr_ino" ]]; then
    printf '\033[0;31m[FAIL]\033[0m  allowlist mount is STALE — %s holds inode %s, the repo file is %s.\n' \
      "$proxy" "$ctr_ino" "$host_ino" >&2
    printf '        This should be impossible under the directory mount. Check whether\n' >&2
    printf '        docker-compose.yml was reverted to a single-FILE bind mount of\n' >&2
    printf '        proxy/allowed_domains.txt — that reintroduces silent blindness.\n' >&2
    printf '        fix: restore the `./proxy:/etc/squid/host:ro` mount, then profile.sh %s up\n' "$PROFILE" >&2
    rc=1
    HOST_FAILS=$(( ${HOST_FAILS:-0} + 1 ))
  elif [[ -n "$host_ino" && "$host_ino" == "$ctr_ino" ]]; then
    ok "allowlist mount is live (inode $host_ino) — proxy sees host edits immediately"
  fi

  # Mode A, DECISIVE — ask squid what it is actually enforcing.
  #
  # This replaces an mtime heuristic (allowlist newer than the proxy's StartedAt
  # => "may be stale"). That warn was wrong in both directions: under the
  # directory mount every git operation touching the allowlist bumps mtime, so it
  # fired on benign checkouts until people learned to ignore it; and StartedAt is
  # blind to `squid -k reconfigure`, so it stayed silent after a real edit that
  # HAD been applied. A permanently-firing warning is furniture.
  #
  # Instead: open a CONNECT to squid's own port from inside the proxy container
  # and read the status line. 403 means the in-memory ACL denies the host —
  # answered from squid's parsed config BEFORE any DNS or upstream connect, so
  # the deny direction costs no egress and works with the internet down. That is
  # the fact the mtime check was guessing at.
  #
  # Only the deny direction is swept, because that is the dangerous one (a host
  # the repo revoked but the proxy still permits) and it is free. One allowed
  # canary is probed to catch "squid is enforcing some other list entirely".
  local denied probe_out n_denied
  denied=$(list_denied_domains "$allowlist")
  n_denied=$(printf '%s\n' "$denied" | grep -c . || true)

  if [[ -e "$PROFILES_ROOT/.egress-widened-$PROFILE" ]]; then
    info "enforcement probe skipped — a with-egress window is open for $PROFILE"
  elif [[ "$n_denied" -eq 0 ]]; then
    info "enforcement probe skipped — no commented-out domains to test"
  else
    # One exec for the whole sweep. Per-domain read timeout so a wedged squid
    # cannot stall verify; outer timeout caps the worst case regardless.
    probe_out=$(printf '%s\n%s\n' "$denied" "$ALLOWLIST_CANARY" \
      | timeout 90 docker exec -i "$proxy" bash -c '
          while IFS= read -r d; do
            [ -n "$d" ] || continue
            code=TIMEOUT
            if exec 3<>/dev/tcp/127.0.0.1/3128 2>/dev/null; then
              printf "CONNECT %s:443 HTTP/1.1\r\nHost: %s:443\r\n\r\n" "$d" "$d" >&3
              read -t 3 -r _proto code _rest <&3 || code=TIMEOUT
              exec 3<&- 3>&-
            else
              code=NOCONNECT
            fi
            printf "%s %s\n" "$d" "$code"
          done' 2>/dev/null) || probe_out=""

    if [[ -z "$probe_out" ]]; then
      warn "enforcement probe could not run against $proxy — squid's in-memory allowlist was NOT verified (the file checks above still passed)"
      HOST_WARNS=$(( ${HOST_WARNS:-0} + 1 ))
    else
      local permitted odd unreachable canary_code
      # The canary is the last line; everything before it is the denied sweep.
      canary_code=$(printf '%s\n' "$probe_out" | awk -v c="$ALLOWLIST_CANARY" '$1==c {print $2}' | tail -1)
      permitted=$(printf '%s\n' "$probe_out" | awk -v c="$ALLOWLIST_CANARY" '$1!=c && $2=="200" {print $1}')
      odd=$(printf '%s\n' "$probe_out" | awk -v c="$ALLOWLIST_CANARY" '$1!=c && $2!="200" && $2!="403" {print $1" ("$2")"}')
      unreachable=$(printf '%s\n' "$odd" | grep -cE '\((TIMEOUT|NOCONNECT)\)$' || true)

      if [[ -n "$permitted" ]]; then
        printf '\033[0;31m[FAIL]\033[0m  %s PERMITS a domain this repo denies — it is enforcing a stale allowlist\n' "$proxy" >&2
        printf '%s\n' "$permitted" | sed 's/^/        proxy tunnels (repo has it commented out): /' >&2
        printf '        NB: squid answers 200 only after connecting upstream, so each line\n' >&2
        printf '        above is one real connection to a host the repo revoked. That is\n' >&2
        printf '        the evidence, and the reason this is a FAIL and not a warning.\n' >&2
        printf '        fix: docker restart %s   (or `squid -k reconfigure`)\n' "$proxy" >&2
        rc=1
        HOST_FAILS=$(( ${HOST_FAILS:-0} + 1 ))
      fi

      # Anything that is neither 403 nor 200 means the ACL let the request
      # through and something later failed (503 = allowed, upstream unreachable).
      # Arguably also a FAIL; kept a WARN until observed in the wild, because a
      # probe-infrastructure failure must never read as an enforcement verdict.
      if [[ -n "$odd" && "$unreachable" -eq 0 ]]; then
        warn "enforcement probe: unexpected status from $proxy — $(printf '%s' "$odd" | tr '\n' ' ')"
        HOST_WARNS=$(( ${HOST_WARNS:-0} + 1 ))
      elif [[ "$unreachable" -gt 0 ]]; then
        warn "enforcement probe: $unreachable of $n_denied domains unprobeable (squid slow or busy) — those were not verified"
        HOST_WARNS=$(( ${HOST_WARNS:-0} + 1 ))
      fi

      if [[ "$canary_code" == "403" ]]; then
        warn "enforcement probe: $proxy denies $ALLOWLIST_CANARY, which this repo allows — it may be enforcing a different or empty allowlist"
        HOST_WARNS=$(( ${HOST_WARNS:-0} + 1 ))
      fi

      [[ -z "$permitted" && -z "$odd" ]] && \
        ok "allowlist ENFORCED by $proxy ($n_denied denied domains verified 403, $ALLOWLIST_CANARY reachable)"
    fi
  fi
  return "$rc"
}

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
  mkdir -p "$p/claude-home" "$p/cache" "$p/config" "$p/gemini-home" "$p/kaggle"
  if [[ ! -s "$p/claude.json" ]]; then
    printf '{}\n' > "$p/claude.json"
  fi
  mkdir -p "$p/config/git"
  # pnpm: always run the image's pnpm; ignore repo `packageManager` pins.
  # pnpm 10's version manager re-execs a downloaded pnpm from ~/.local/share/
  # pnpm/.tools/ — a noexec tmpfs (audit Finding G) — so any pin that drifts
  # from the image kills every pnpm command with EACCES. Global pnpm rc only;
  # npm never reads it (no warnings). Mirrors init-profile-state.sh.
  mkdir -p "$p/config/pnpm"
  if ! grep -qs '^manage-package-manager-versions=' "$p/config/pnpm/rc"; then
    printf 'manage-package-manager-versions=false\n' >> "$p/config/pnpm/rc"
  fi
  # Gate 2 (pnpm half) — slopsquat quarantine, 10080 MINUTES = 7 days. pnpm's
  # unit is minutes; npm's min-release-age (Dockerfile) is days. Lives here
  # rather than in the image because /root/.config is a per-profile bind mount
  # that would mask an image-layer value. Key must be KEBAB-case: the documented
  # `minimumReleaseAge` spelling is silently ignored in the rc file. Mirrors
  # init-profile-state.sh.
  if ! grep -qs '^minimum-release-age=' "$p/config/pnpm/rc"; then
    printf 'minimum-release-age=10080\n' >> "$p/config/pnpm/rc"
  fi
  cp "$SCRIPT_DIR/sandbox_templates/common/db.env.template" "$p/db.env.example"
  cp "$SCRIPT_DIR/sandbox_templates/common/secrets.env.template" "$p/secrets.env.example"
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
  # Refresh the managed sandbox-notice in the agent's GLOBAL memory
  # (~/.claude/CLAUDE.md, auto-loaded every session) so Claude Code agents see
  # the capabilities/prohibitions even in a workspace repo whose AGENTS.md
  # hasn't been synced yet. Rewrites only the marked block, idempotently.
  if [[ -f "$SCRIPT_DIR/scripts/sync-agent-notice.sh" ]]; then
    bash "$SCRIPT_DIR/scripts/sync-agent-notice.sh" "$p/claude-home/CLAUDE.md" >/dev/null \
      || warn "could not sync sandbox-notice into $p/claude-home/CLAUDE.md"
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
  local git_id_name="${GIT_USER_NAME:-Sandbox User}"
  local git_id_email="${GIT_USER_EMAIL:-sandbox@users.noreply.github.com}"
  if [[ "$git_id_email" != *@users.noreply.github.com ]]; then
    warn "GIT_USER_EMAIL '$git_id_email' is not a users.noreply.github.com address — using default noreply identity"
    git_id_name="Sandbox User"
    git_id_email="sandbox@users.noreply.github.com"
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
  if [[ -f "$p/secrets.env" ]]; then
    chmod 600 "$p/secrets.env" 2>/dev/null || warn "could not chmod 600 $p/secrets.env"
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

# --- `health` — cross-profile consistency check (no profile arg) -------------
# Read-only. For EVERY known profile (state dir OR live container) it checks
# the containers that MUST run together:
#   agent  ai-sandbox-<p>     proxy  egress-proxy-<p>
#   + the configured DB sibling(s): postgres-<p> / mongo-<p>, per the profile's
#     persisted compose-profiles default (db-postgres|db-mongo|db-all).
# A profile with NOTHING running is assumed intentionally down (OK). A profile
# with SOME containers up but an expected sibling missing/exited is DEGRADED
# and flagged with a fix hint — this is the proxy-exited (ECONNREFUSED :3128)
# and stale-DB failure modes. Orphan DBs (a DB up while its agent is down) are
# flagged too. Never starts or stops anything. Exit 1 if any profile is
# DEGRADED, so it doubles as a tripwire (`just health` in CI/pre-flight).
if [[ "${1:-}" == "health" ]]; then
  shopt -s nullglob
  C_G=$'\033[0;32m'; C_R=$'\033[0;31m'; C_Y=$'\033[1;33m'; C_D=$'\033[0;90m'; C_0=$'\033[0m'

  # One snapshot of every container's name + coarse state (running/exited/...).
  snapshot="$(docker ps -a --format '{{.Names}}'$'\t''{{.State}}' 2>/dev/null || true)"
  cstate() { awk -F '\t' -v n="$1" '$1==n{print $2; f=1} END{if(!f) print "absent"}' <<<"$snapshot"; }
  slab()   { case "$1" in running) printf 'up';; absent) printf -- '-';; *) printf '%s' "$1";; esac; }

  # Profiles = state dirs UNION profiles implied by any existing container, so
  # an orphan container under a wiped/never-created profile still surfaces.
  profiles="$(
    { for d in "$PROFILES_ROOT"/*/; do [[ -d "$d" ]] && basename "$d"; done
      printf '%s\n' "$snapshot" | awk -F '\t' '{print $1}' \
        | sed -n -E 's/^(ai-sandbox|egress-proxy|postgres|mongo)-(.+)$/\2/p'
    } | sort -u
  )"
  if [[ -z "$profiles" ]]; then
    echo "(no profiles and no sandbox containers found)"
    exit 0
  fi

  printf "${C_D}Host state: %s   |   up=running, exited/created/…=present-not-running, -=absent${C_0}\n\n" "$PROFILES_ROOT"
  printf '\033[1m%-18s %-8s %-8s %-16s %s\033[0m\n' PROFILE AGENT PROXY DB VERDICT
  flags=()
  degraded=0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    a_s=$(cstate "ai-sandbox-$p"); x_s=$(cstate "egress-proxy-$p")
    g_s=$(cstate "postgres-$p");   m_s=$(cstate "mongo-$p")

    cur=""; f="$PROFILES_ROOT/$p/compose-profiles"
    [[ -f "$f" ]] && { read -r cur < "$f" || true; }
    exp_pg=0; exp_mongo=0
    case "$cur" in
      db-postgres) exp_pg=1 ;;
      db-mongo)    exp_mongo=1 ;;
      db-all)      exp_pg=1; exp_mongo=1 ;;
    esac

    a_run=0; [[ "$a_s" == running ]] && a_run=1
    x_run=0; [[ "$x_s" == running ]] && x_run=1
    g_run=0; [[ "$g_s" == running ]] && g_run=1
    m_run=0; [[ "$m_s" == running ]] && m_run=1
    active=$(( a_run || x_run || g_run || m_run ))

    # DB cell: show each expected DB's state; mark unexpected-but-running with '!'.
    parts=()
    (( exp_pg ))          && parts+=("pg:$(slab "$g_s")")
    (( exp_mongo ))       && parts+=("mongo:$(slab "$m_s")")
    (( !exp_pg && g_run )) && parts+=("pg:up!")
    (( !exp_mongo && m_run )) && parts+=("mongo:up!")
    if (( ${#parts[@]} == 0 )); then db_cell='-'; else db_cell="${parts[*]}"; fi

    if (( ! active )); then
      verdict="down"; color="$C_D"
      # Fully down is fine, but note any stopped leftovers worth cleaning.
      for pair in "ai-sandbox-$p=$a_s" "egress-proxy-$p=$x_s" "postgres-$p=$g_s" "mongo-$p=$m_s"; do
        nm="${pair%=*}"; st="${pair##*=}"
        case "$st" in
          absent|running) ;;
          *) flags+=("WARN  $p: leftover $nm ($st) — 'scripts/profile.sh $p down' to clean") ;;
        esac
      done
    else
      probs=()
      (( a_run )) || probs+=("agent ai-sandbox-$p is $(slab "$a_s") (expected running) — scripts/profile.sh $p up")
      (( x_run )) || probs+=("egress-proxy-$p is $(slab "$x_s") — egress DOWN (ECONNREFUSED …:3128 on auth/network) — scripts/profile.sh $p up  (quick: docker start egress-proxy-$p)")
      (( !exp_pg    || g_run )) || probs+=("postgres-$p is $(slab "$g_s") but DB default is '$cur' — scripts/profile.sh $p up")
      (( !exp_mongo || m_run )) || probs+=("mongo-$p is $(slab "$m_s") but DB default is '$cur' — scripts/profile.sh $p up")
      # Orphan DBs: running but not configured. Harmless if agent is up
      # (likely a one-shot COMPOSE_PROFILES); a stale hazard if agent is down.
      if (( !exp_pg && g_run )); then
        if (( a_run )); then flags+=("WARN  $p: postgres-$p up but not the persisted default (one-shot COMPOSE_PROFILES? — 'scripts/profile.sh $p db enable postgres' to persist)")
        else probs+=("postgres-$p running but agent is down — orphan/stale DB — docker rm -f postgres-$p  (or scripts/profile.sh $p up)"); fi
      fi
      if (( !exp_mongo && m_run )); then
        if (( a_run )); then flags+=("WARN  $p: mongo-$p up but not the persisted default (one-shot COMPOSE_PROFILES? — 'scripts/profile.sh $p db enable mongo' to persist)")
        else probs+=("mongo-$p running but agent is down — orphan/stale DB — docker rm -f mongo-$p  (or scripts/profile.sh $p up)"); fi
      fi
      if (( ${#probs[@]} == 0 )); then
        verdict="OK"; color="$C_G"
      else
        verdict="DEGRADED"; color="$C_R"; degraded=1
        for pr in "${probs[@]}"; do flags+=("FAIL  $p: $pr"); done
      fi
    fi

    printf "%-18s %-8s %-8s %-16s ${color}%s${C_0}\n" \
      "$p" "$(slab "$a_s")" "$(slab "$x_s")" "$db_cell" "$verdict"
  done <<< "$profiles"

  if (( ${#flags[@]} )); then
    echo
    printf '\033[1mflags:\033[0m\n'
    for fl in "${flags[@]}"; do
      case "$fl" in
        FAIL*) printf "  ${C_R}%s${C_0}\n" "$fl" ;;
        WARN*) printf "  ${C_Y}%s${C_0}\n" "$fl" ;;
        *)     printf '  %s\n' "$fl" ;;
      esac
    done
  else
    echo; ok "all profiles consistent (each fully up, or fully down)"
  fi
  exit $(( degraded ))
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
  docker image prune -f "${IMAGE_PRUNE_FILTER[@]}"
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
    docker image prune -f "${IMAGE_PRUNE_FILTER[@]}"
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

    # ---- host-side tier-1 checks --------------------------------------------
    # These CANNOT live in verify-sandbox.sh: that script is streamed into the
    # AGENT container, which can see neither this repo (the sandbox repo is not
    # bind-mounted into /workspace) nor the proxy container. Anything comparing
    # host state against the proxy has to run here.
    verify_rc=0
    HOST_WARNS=0; HOST_FAILS=0
    check_allowlist_sync || verify_rc=1

    info "Running verify-sandbox.sh inside $AGENT (streamed via stdin)"
    # NOT `exec` — the host-side result above still has to affect the exit code.
    docker exec -i "$AGENT" bash -s -- "$@" < "$src" || verify_rc=1

    # The tally printed above is the CONTAINER's, and it cannot count these:
    # the host-side checks run here, before the stream. Without this line a run
    # prints a loud host-side WARN and then "0 warnings", and the summary is
    # what gets read. That is not hypothetical — it is how a stale-inode proxy
    # survived a full post-merge verification pass on 2026-08-02.
    if (( HOST_WARNS > 0 || HOST_FAILS > 0 )); then
      printf '\033[1;33m== host-side (not in the tally above): %d failed | %d warning(s) ==\033[0m\n' \
        "$HOST_FAILS" "$HOST_WARNS" >&2
    fi
    exit "$verify_rc"
    ;;

  deps)
    # Dependency posture for the profile's workspace. Runs HOST-SIDE: depaudit is
    # read-only and spawns nothing, and the OSV cross-check needs api.osv.dev,
    # which is deliberately NOT in the egress allowlist — keeping it on the host
    # means the check costs no egress surface inside any profile (plan D1/D6).
    # Routed through profile.sh anyway, per golden rule 1: discovery of what a
    # profile can do lives here, not in a script the user has to know about.
    da="$SCRIPT_DIR/scripts/depaudit.py"
    [[ -f "$da" ]] || fail "depaudit.py missing: $da"
    command -v python3 >/dev/null 2>&1 || fail "python3 not found on the host (depaudit needs 3.11+)"
    python3 -c 'import sys,tomllib' 2>/dev/null \
      || fail "python3 is too old for depaudit (needs 3.11+ for tomllib): $(python3 -V 2>&1)"

    # --history reads back the T22 install-window log and returns. It is a
    # different question from posture — "what came in, and what did it reach"
    # rather than "how is this repo configured" — and needs no workspace, so it
    # short-circuits before the workspace check below.
    if [[ "${1:-}" == "--history" ]]; then
      hist="$PROFILES_ROOT/$PROFILE/audit/depgate.jsonl"
      [[ -f "$hist" ]] || { info "No install windows recorded yet for '$PROFILE'."; \
        info "The log is written by scripts/with-egress.sh, which per ADR-0003 is the only route a dependency can take."; exit 0; }
      shift
      hist_n="${1:-20}"
      python3 - "$hist" "$hist_n" <<'PY'
import json, sys, datetime

path, want = sys.argv[1], int(sys.argv[2])
rows = []
for line in open(path, encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        rows.append(json.loads(line))
    except json.JSONDecodeError:
        # A partial line means a run was killed mid-append. Say so; do not
        # silently drop it, or the log looks complete when it is not.
        rows.append(None)

shown = rows[-want:]
bad = sum(1 for r in shown if r is None)
print(f"{len(rows)} window(s) recorded; showing last {len(shown)}\n")
for r in shown:
    if r is None:
        print("  ??  <unparseable line — a run was interrupted mid-write>")
        continue
    when = datetime.datetime.fromtimestamp(r["ts_open"]).strftime("%Y-%m-%d %H:%M")
    eg = r.get("egress", {})
    denied = eg.get("denied", [])
    add = r.get("modules_added", {}).get("count", 0)
    rem = r.get("modules_removed", {}).get("count", 0)
    locks = r.get("lockfiles_changed", [])
    flag = "!" if (denied or r.get("rc")) else " "
    print(f"{flag} {when}  {r['duration_s']:>4}s  rc={r.get('rc',0)}  "
          f"[{','.join(r.get('sections', [])) or '-'}]  modules +{add}/-{rem}  "
          f"lockfiles {len(locks)}")
    print(f"     cmd: {r.get('cmd','')[:100]}")
    if eg.get("allowed"):
        print(f"     reached: {', '.join(eg['allowed'][:8])}"
              + (f" (+{len(eg['allowed'])-8} more)" if len(eg["allowed"]) > 8 else ""))
    if denied:
        print(f"     DENIED : {', '.join(denied)}")
    for p in r.get("preflight", []):
        if p.get("verdict") not in ("NO-KNOWN-MAL", ""):
            print(f"     preflight {p['verdict']}: {p['eco']}/{p['name']} — {p.get('detail','')}")
    if locks:
        print(f"     lockfiles: {', '.join(locks)}")
    print()
if bad:
    print(f"WARNING: {bad} unparseable line(s) in {path}")
PY
      exit 0
    fi

    ws="$REPO_ROOT/$PROFILE"
    [[ -d "$ws" ]] || fail "Workspace does not exist: $ws"

    dep_osv=0; dep_fmt="md"; dep_failon="warn"
    for a in "$@"; do
      case "$a" in
        --osv)     dep_osv=1 ;;
        --json)    dep_fmt="json" ;;
        --strict)  dep_failon="fail" ;;
        --quiet)   dep_failon="never" ;;
        *) fail "Unknown flag for deps: $a
      Usage: scripts/profile.sh $PROFILE deps [--osv] [--json] [--strict|--quiet]
             scripts/profile.sh $PROFILE deps --history [N]" ;;
      esac
    done

    # A profile's workspace holds MANY repos (docker-compose.yml: "the profile's
    # repo parent folder = /workspace"). depaudit is root-scoped by design, so
    # iterate: the workspace root, plus each immediate child that has a manifest.
    # Without this the common case reports "no manifests" and reads as clean.
    dep_roots=""
    for m in package.json pyproject.toml requirements.txt Pipfile; do
      [[ -e "$ws/$m" ]] && { dep_roots="$ws"; break; }
    done
    for d in "$ws"/*/; do
      [[ -d "$d" ]] || continue
      for m in package.json pyproject.toml requirements.txt Pipfile; do
        [[ -e "$d$m" ]] && { dep_roots="$dep_roots ${d%/}"; break; }
      done
    done
    [[ -n "${dep_roots// /}" ]] || { warn "No manifests found under $ws"; exit 0; }

    dep_rc=0
    dep_summary=""
    for r in $dep_roots; do
      rel="${r#$REPO_ROOT/}"
      [[ "$dep_fmt" == "md" ]] && info "depaudit posture: $rel"
      dep_out=$(python3 "$da" posture "$r" --format "$dep_fmt" --fail-on "$dep_failon") || dep_rc=1
      printf '%s\n' "$dep_out"
      if [[ "$dep_fmt" == "md" ]]; then
        counts=$(printf '%s\n' "$dep_out" | grep -m1 '^| FAIL ' | tr -d '|' | tr -s ' ')
        dep_summary="${dep_summary}${rel}|${counts}
"
      fi
      if [[ "$dep_osv" -eq 1 ]]; then
        [[ "$dep_fmt" == "md" ]] && info "depaudit OSV malicious-package check: $rel"
        osv_out=$(python3 "$da" deps "$r" --format "$dep_fmt") || dep_rc=1
        printf '%s\n' "$osv_out"
        if [[ "$dep_fmt" == "md" ]]; then
          blocked=$(printf '%s\n' "$osv_out" | grep -c '^\- \*\*\[BLOCK\]' || true)
          [[ "${blocked:-0}" -gt 0 ]] && dep_summary="${dep_summary}${rel}|  OSV BLOCK ${blocked}
"
        fi
      fi
    done

    # A nine-repo workspace produces nine reports; without a roll-up the reader
    # has to scroll and diff them by eye, which is how a FAIL gets missed.
    if [[ "$dep_fmt" == "md" && -n "$dep_summary" ]]; then
      printf '\n%s\n' "=========================================================="
      printf '%s\n' "SUMMARY — $PROFILE workspace ($REPO_ROOT/$PROFILE)"
      printf '%s\n' "=========================================================="
      printf '%s' "$dep_summary" | while IFS='|' read -r name counts; do
        [[ -z "$name" ]] && continue
        printf '  %-32s %s\n' "$name" "$counts"
      done
      printf '%s\n' "----------------------------------------------------------"
      printf '%s\n' "  depaudit is READ-ONLY and reports on configuration; it does"
      printf '%s\n' "  not enforce anything. FAIL = a control that is absent, not"
      printf '%s\n' "  a vulnerability. Fixes belong in the repo it names."
    fi
    exit "$dep_rc"
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
    echo "    $p/secrets.env  (if present)"
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
    [[ -f "$p/secrets.env" ]]                   && mv "$p/secrets.env"                   "$stage/secrets.env"
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
    [[ -f "$stage/secrets.env" ]]                   && mv "$stage/secrets.env"                   "$p/secrets.env"

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
    [[ -f "$p/secrets.env" ]]                   && chmod 600 "$p/secrets.env"
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
