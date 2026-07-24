#!/usr/bin/env bash
# =============================================================================
# code-attach.sh — open a SPECIFIC folder in a running agent container in VS Code
# =============================================================================
# Usage:
#   scripts/code-attach.sh <profile> [folder] [-- code-args...]
#
# Examples:
#   scripts/code-attach.sh therapod                    # list repos under /workspace
#   scripts/code-attach.sh therapod app_blast          # -> /workspace/app_blast
#   scripts/code-attach.sh nranthony /workspace/deep/path
#   scripts/code-attach.sh therapod app_blast -r       # reuse the current window
#
# Why this exists alongside `profile.sh <profile> attach`:
#   - `attach` gives you a zsh shell inside the container.
#   - this opens the VS Code *window* against a folder in the same already-
#     running, already-hardened container. It starts nothing and changes no
#     container state — it is a pure host-side addressing helper.
#
# Why not the "Attach to Running Container" menu / a devcontainer.json:
#   The menu reopens whatever folder you had open last. VS Code records
#   (container + folder) in its recent-window history and that history WINS
#   over the `workspaceFolder` key in the attached-container config files
#   (globalStorage/ms-vscode-remote.remote-containers/{nameConfigs,imageConfigs}),
#   so editing those has no effect once a container has any history. Naming the
#   folder in the URI bypasses history entirely — and needs no devcontainer.json
#   in the repo, so the container's hardening is untouched.
#
# Mechanism: VS Code addresses a folder-in-a-container as
#   vscode-remote://attached-container+<hex>/<path>
# where <hex> is the hex-encoded JSON authority naming the container AND the
# docker context. The context must be `rootless` — that is the sandbox's
# security boundary (container UID 0 <-> host UID 1000); pointing at the
# default context would miss these containers entirely.
# Override with SANDBOX_VSCODE_CONTEXT if your context is named differently.
# SANDBOX_CODE_DRYRUN=1 prints the resulting URI instead of opening a window.
# =============================================================================
set -euo pipefail

info() { printf '\033[0;36m[INFO]\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
die()  { printf '\033[0;31m[ERR]\033[0m   %s\n' "$*" >&2; exit 1; }

DOCKER_CONTEXT_NAME="${SANDBOX_VSCODE_CONTEXT:-rootless}"

[ $# -ge 1 ] || die "usage: scripts/code-attach.sh <profile> [folder] [-- code-args...]"

profile="$1"; shift

# Accept a bare profile ("therapod") or the full container name.
case "$profile" in
  ai-sandbox-*) container="$profile" ;;
  *)            container="ai-sandbox-$profile" ;;
esac

folder=""
if [ $# -gt 0 ] && [ "$1" != "--" ]; then
  folder="$1"; shift
fi
[ "${1:-}" = "--" ] && shift   # allow an explicit -- before code args

command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
command -v code   >/dev/null 2>&1 || die "the 'code' CLI is not on PATH (VS Code shell command)"

# The container must already be up — this script never starts anything.
docker ps --format '{{.Names}}' | grep -qx "$container" \
  || die "container '$container' is not running — start it with: just up $profile"

# No folder given: show what's there rather than guessing.
if [ -z "$folder" ]; then
  info "repos under /workspace in $container:"
  docker exec "$container" ls -1 /workspace 2>/dev/null | sed 's/^/  /' || true
  echo
  die "pick one: scripts/code-attach.sh $profile <folder>"
fi

# Bare name -> /workspace/<name>; an absolute path is used as-is.
case "$folder" in
  /*) path="$folder" ;;
  *)  path="/workspace/$folder" ;;
esac

docker exec "$container" test -d "$path" \
  || die "'$path' does not exist in $container (run without a folder to list)"

# Build the attached-container authority exactly as VS Code encodes it.
# On WSL2 it also records a Windows-side cwd (UNC path to the distro root);
# on bare Linux VS Code runs natively and omits it.
if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then
  distro="${WSL_DISTRO_NAME:-Ubuntu-24.04}"
  json='{"containerName":"/'"$container"'","settings":{"context":"'"$DOCKER_CONTEXT_NAME"'"},"cwd":"\\\\wsl.localhost\\'"$distro"'\\"}'
else
  json='{"containerName":"/'"$container"'","settings":{"context":"'"$DOCKER_CONTEXT_NAME"'"}}'
fi

if command -v xxd >/dev/null 2>&1; then
  hex="$(printf '%s' "$json" | xxd -p | tr -d '\n')"
else
  hex="$(printf '%s' "$json" | od -An -tx1 | tr -d ' \n')"
fi

uri="vscode-remote://attached-container+${hex}${path}"

# SANDBOX_CODE_DRYRUN=1 prints the URI instead of opening a window.
if [ -n "${SANDBOX_CODE_DRYRUN:-}" ]; then
  printf '%s\n' "$uri"
  exit 0
fi

info "opening $container : $path"
exec code --folder-uri "$uri" "$@"
