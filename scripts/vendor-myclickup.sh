#!/usr/bin/env bash
# =============================================================================
# vendor-myclickup.sh — copy the myclickup payload (wheel + agent skill) into
#                       this build context, or verify the copy still matches
# =============================================================================
# myclickup (nranthony/myclickup) is a PRIVATE repo that ships a zero-dependency
# pure-Python wheel. Its ADR-0002 vendors that wheel here because
# `docker-compose.yml` sets `build.context: .` — COPY cannot read a sibling
# checkout, and a network install at build would need a deploy token inside the
# build of a security-critical image.
#
# THE PAYLOAD IS GITIGNORED, and that is the whole design constraint:
# windows-ai-sandbox is PUBLIC and myclickup is PRIVATE, so committing a
# py3-none-any wheel here would publish the tool's source (a wheel is a zip of
# the .py files). Consequences you must know:
#
#   * The image is NOT reproducible from a clone of this repo alone. A host
#     without the myclickup checkout builds fine — the Dockerfile's install is
#     conditional — but the resulting image has no `myclickup`.
#   * `.gitignore` keeps `sandbox_templates/wheels/.gitkeep` tracked so the
#     directory exists in the build context. The Dockerfile does a DIRECTORY
#     COPY for the same reason: `COPY …/myclickup-*.whl` is a hard build failure
#     when the glob matches nothing, which would break every clone.
#   * `sandbox_templates/skills/myclickup/` is gitignored too, so wheel and skill
#     stay in lockstep. Seeding converges (ADR-0005), so a profile that once had
#     the skill loses it on the next `up` if the payload is gone — correct, but
#     it means "vendor, then build" is the only supported order.
#
# Why --check compares CONTENT, not version strings: pre-1.0 the version changes
# rarely and the tree changes constantly, so the common drift case is a rebuilt
# 0.2.0 wheel with different bytes — which a filename check passes while the
# image ships something other than the source. It is not a hash-vs-fresh-build
# comparison either: `uv build` makes no byte-reproducibility promise, so that
# would false-alarm.
#
# HOST-SIDE ONLY. In-container the mktemp cleanup is refused by the sandbox's
# destructive-command hook, and vendoring is a host step by construction.
#
# Usage:
#   scripts/vendor-myclickup.sh            # build from source, then vendor
#   scripts/vendor-myclickup.sh --check    # verify the vendored payload matches
#
# Source checkout resolution, in order:
#   $MYCLICKUP_DIR
#   .myclickup-dir.local        (gitignored, one line — the only machine-specific
#                                fact in this flow; mirrors .conventions-dir.local)
#   ../../nranthony/myclickup   relative to this repo
# =============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

WHEEL_DIR="$REPO_ROOT/sandbox_templates/wheels"
SKILL_DIR="$REPO_ROOT/sandbox_templates/skills/myclickup"

die()  { printf 'vendor-myclickup: %s\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }

# --- resolve the source checkout ---------------------------------------------
resolve_src() {
  local candidate=""
  if [[ -n "${MYCLICKUP_DIR:-}" ]]; then
    candidate="$MYCLICKUP_DIR"
  elif [[ -f "$REPO_ROOT/.myclickup-dir.local" ]]; then
    candidate="$(head -n1 "$REPO_ROOT/.myclickup-dir.local" | tr -d '\r')"
  else
    candidate="$REPO_ROOT/../../nranthony/myclickup"
  fi
  # shellcheck disable=SC2088  # deliberate: expand a leading ~ ourselves
  case "$candidate" in "~/"*) candidate="$HOME/${candidate#\~/}" ;; esac
  [[ -d "$candidate" ]] || die "source checkout not found: $candidate
  Set MYCLICKUP_DIR, or write the path into .myclickup-dir.local (gitignored)."
  [[ -f "$candidate/pyproject.toml" ]] || die "not a myclickup checkout (no pyproject.toml): $candidate"
  (cd "$candidate" && pwd)
}

src_version() {
  grep -m1 '^version' "$1/pyproject.toml" | cut -d'"' -f2
}

# The wheel path comes from a glob, NOT `whl=$(ls …)`: `ls` is `lsd` on this
# host, so command substitution returns a decorated line rather than a path and
# every step downstream silently misfires. The count guard also catches the
# two-wheels case, which would otherwise leave the Dockerfile choosing between
# them at build time.
vendored_wheel() {
  local whls=()
  shopt -s nullglob
  whls=("$WHEEL_DIR"/myclickup-*.whl)
  shopt -u nullglob
  if [[ ${#whls[@]} -ne 1 ]]; then
    die "expected exactly 1 vendored wheel in sandbox_templates/wheels/, found ${#whls[@]}"
  fi
  printf '%s' "${whls[0]}"
}

# --- vendor -------------------------------------------------------------------
do_vendor() {
  local src ver
  src="$(resolve_src)"
  info "source: $src"

  # Build first. Copying whatever dist/ happens to hold is the stale-wheel
  # failure mode with extra steps. `just dist` runs the tool's tests first; a
  # test failure aborting the vendor is intended, not a snag to work around.
  #
  # UV_PROJECT_ENVIRONMENT is pointed OUT of the source checkout on purpose. A
  # bind-mounted repo has ONE `.venv` but two possible creators, and console
  # scripts carry an absolute shebang: a `.venv` synced inside a profile has
  # `#!/workspace/myclickup/.venv/bin/python3`, which on the host fails as
  # "Failed to spawn: pytest / No such file or directory" — a message that reads
  # like a missing dev dependency, not a path mismatch. Rebuilding it host-side
  # would just break the container's copy on the next attach. So the vendor build
  # gets its own env outside both repos and the checkout's `.venv` is left alone.
  ( cd "$src" \
    && UV_PROJECT_ENVIRONMENT="${XDG_CACHE_HOME:-$HOME/.cache}/windows-ai-sandbox/myclickup-venv" \
       just dist )

  mkdir -p "$WHEEL_DIR" "$SKILL_DIR"
  rm -f "$WHEEL_DIR"/myclickup-*.whl
  cp "$src"/dist/myclickup-*.whl "$WHEEL_DIR"/
  cp "$src/packaging/sandbox/SKILL.md" "$SKILL_DIR/SKILL.md"

  ver="$(src_version "$src")"
  info "vendored: $(basename "$(vendored_wheel)") ($ver) + SKILL.md"
  printf '\nNext: scripts/profile.sh build   (the image is not rebuilt by `up`)\n'
  printf 'Then: scripts/profile.sh <p> recreate   (per profile; also re-reads secrets.env)\n'
}

# --- check --------------------------------------------------------------------
do_check() {
  local src ver whl tmp
  src="$(resolve_src)"
  ver="$(src_version "$src")"
  whl="$(vendored_wheel)"

  case "$whl" in
    *"myclickup-${ver}-"*) : ;;
    *) die "MISMATCH: $(basename "$whl") vs source version $ver" ;;
  esac

  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand $tmp now, not at trap time
  trap "rm -rf '$tmp'" EXIT
  python3 -m zipfile -e "$whl" "$tmp"

  if ! diff -r -x '__pycache__' -x '*.pyc' "$src/src/myclickup" "$tmp/myclickup"; then
    die "DRIFT: vendored wheel content != $src/src/myclickup — re-run without --check"
  fi
  if ! diff -q "$src/packaging/sandbox/SKILL.md" "$SKILL_DIR/SKILL.md"; then
    die "DRIFT: vendored skill != $src/packaging/sandbox/SKILL.md — re-run without --check"
  fi
  printf 'vendor-check OK: %s (%s) + skill match source\n' "$(basename "$whl")" "$ver"
}

case "${1:-vendor}" in
  vendor)         do_vendor ;;
  --check|check)  do_check ;;
  *) die "unknown argument '$1' (want: no args, or --check)" ;;
esac
