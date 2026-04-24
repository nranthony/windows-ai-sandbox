#!/usr/bin/env bash
# =============================================================================
# trivy-scan.sh — static + image security scan for windows-ai-sandbox
# =============================================================================
# Usage: scripts/trivy-scan.sh [config|secret|image|all]  (default: all)
#
# Runs on the WSL host, not inside a container. Requires `trivy` on PATH:
#   sudo apt-get install wget apt-transport-https gnupg
#   wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | \
#     sudo gpg --dearmor -o /usr/share/keyrings/trivy.gpg
#   echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] \
#     https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" | \
#     sudo tee /etc/apt/sources.list.d/trivy.list
#   sudo apt-get update && sudo apt-get install trivy
#
# First run downloads the CVE DB (~700MB, cached under ~/.cache/trivy).
#
# Modes:
#   config   misconfig scan of Dockerfile + docker-compose.yml
#   secret   secret scan of the repo (catches accidentally-committed creds —
#            container_testing/.venv is skipped to avoid noise from stdlib)
#   image    CVE scan of the built windows-ai-sandbox:latest image
#            (HIGH/CRITICAL, fixed-only — drops the Ubuntu "won't fix" noise)
#   all      run all three (default)
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="windows-ai-sandbox:latest"
IGNORE_FILE="$REPO_DIR/.trivyignore.yaml"
MODE="${1:-all}"

command -v trivy >/dev/null || { echo "trivy not found — see script header for install instructions" >&2; exit 1; }

hdr() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }

run_config() {
  hdr "config scan (Dockerfile + docker-compose.yml misconfig)"
  trivy config --exit-code 0 --ignorefile "$IGNORE_FILE" "$REPO_DIR"
}

run_secret() {
  hdr "secret scan (repo tree)"
  # Skip local venvs and archived material — noise, not shipped to users.
  trivy fs --scanners secret \
    --skip-dirs "container_testing/.venv,archived_script_ref,reports" \
    --exit-code 0 "$REPO_DIR"
}

run_image() {
  hdr "image CVE scan ($IMAGE, HIGH/CRITICAL, fixed-only)"
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "image $IMAGE not found locally — build first: scripts/profile.sh build" >&2
    return 1
  fi
  trivy image \
    --severity HIGH,CRITICAL \
    --ignore-unfixed \
    --ignorefile "$IGNORE_FILE" \
    --exit-code 0 \
    "$IMAGE"
}

case "$MODE" in
  config) run_config ;;
  secret) run_secret ;;
  image)  run_image ;;
  all)    run_config; run_secret; run_image ;;
  *) echo "usage: $0 [config|secret|image|all]" >&2; exit 1 ;;
esac
