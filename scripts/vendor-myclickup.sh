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
#
# There is deliberately NO guessed fallback path. One used to sit here
# (`../../nranthony/myclickup`) and it is what made the 2026-08-14 repo move
# invisible: when the checkout moved under the channel root, --check printed
# "no myclickup checkout at ../../nranthony/myclickup" and exited 0, which is
# the SAME output as a machine that never configured one. A guess collapses two
# states that must stay distinguishable, and the collapsed state is the silent
# one. `sync-skills-from-conventions.sh` never had a guess; this now matches it.
#
# Three states, three outcomes (--check):
#   nothing configured           -> SKIP, exit 0   (ordinary: fresh clone)
#   configured, target missing   -> FAIL, exit 1   (broken pointer, never ordinary)
#   configured and present       -> compare
# =============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

WHEEL_DIR="$REPO_ROOT/sandbox_templates/wheels"
SKILL_DIR="$REPO_ROOT/sandbox_templates/skills/myclickup"

die()  { printf 'vendor-myclickup: %s\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }
# A drift check that was never CONFIGURED must say so and stand down — NOT
# fail. This repo is public and nranthony/myclickup is private, so "no checkout
# here" and "nothing vendored here" are both ordinary states, not defects.
# Reporting them as failures is a false alarm, and a check that cries wolf gets
# ignored, which costs more than the check was ever worth.
#
# A check whose configured target has VANISHED is the opposite case and fails:
# somebody wrote that path down on purpose, so its absence is a broken pointer,
# and standing down there is how drift goes unwatched for days.
skip() { printf '\033[1;35m[SKIP]\033[0m  vendor-myclickup: %s\n' "$*"; }

# Where the checkout WOULD be, or EMPTY when nothing is configured — no
# validation, no exit. Split out because resolve_src is called as
# `$(resolve_src)`, and an exit inside a command substitution leaves only the
# SUBSHELL: the caller carries on with an empty path and the message captured
# into a variable instead of printed.
src_candidate() {
  local candidate=""
  if [[ -n "${MYCLICKUP_DIR:-}" ]]; then
    candidate="$MYCLICKUP_DIR"
  elif [[ -f "$REPO_ROOT/.myclickup-dir.local" ]]; then
    # First non-blank, non-comment line — the same parser
    # sync-skills-from-conventions.sh uses on .conventions-dir.local. It was
    # `head -n1` here, so the two sibling pointer files did not accept the same
    # file format: the conventions one carries a comment header, and copying
    # that convention across read the comment AS the path.
    candidate="$(awk 'NF && $0 !~ /^[[:space:]]*#/ { print; exit }' \
                   "$REPO_ROOT/.myclickup-dir.local" | tr -d '\r')"
  fi
  # shellcheck disable=SC2088  # deliberate: expand a leading ~ ourselves
  case "$candidate" in "~/"*) candidate="$HOME/${candidate#\~/}" ;; esac
  printf '%s' "$candidate"
}

# Which of the two sources named the path — quoted back in every failure, so a
# broken pointer says WHERE to go and fix it rather than only what is missing.
src_origin() {
  if [[ -n "${MYCLICKUP_DIR:-}" ]]; then
    printf '$MYCLICKUP_DIR'
  else
    printf '%s' "$REPO_ROOT/.myclickup-dir.local"
  fi
}

# --- resolve the source checkout ---------------------------------------------
resolve_src() {
  local candidate
  candidate="$(src_candidate)"
  [[ -n "$candidate" ]] || die "myclickup location unknown. Set one of:
    MYCLICKUP_DIR=/path/to/myclickup scripts/vendor-myclickup.sh
    echo /path/to/myclickup > $REPO_ROOT/.myclickup-dir.local   (gitignored)"
  [[ -d "$candidate" ]] || die "source checkout does not exist (from $(src_origin)): $candidate"
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
  local src ver whl tmp cand
  # Pre-flight: "never configured" and "nothing vendored" mean there is nothing
  # to compare, not that something has drifted. The payload is gitignored, so a
  # fresh clone legitimately has neither — those stand down.
  #
  # A configured path that does not resolve is NOT that state and fails. It is
  # the state this repo was in all of 2026-08-14: the checkout moved under the
  # channel root, the pointer still named the old location, and --check reported
  # a clean stand-down while the wheel sat three releases behind.
  cand="$(src_candidate)"
  if [[ -z "$cand" ]]; then
    skip "no myclickup checkout configured — payload drift NOT checked.
       set MYCLICKUP_DIR, or: echo /path/to/myclickup > .myclickup-dir.local"
    return 0
  fi
  if [[ ! -d "$cand" ]]; then
    die "configured checkout is absent (from $(src_origin)): $cand
       the pointer names a path that does not exist — repoint it, do not delete
       it: an empty pointer stands down silently and stops watching the boundary"
  fi
  if [[ ! -f "$cand/pyproject.toml" ]]; then
    die "not a myclickup checkout (no pyproject.toml, from $(src_origin)): $cand"
  fi
  shopt -s nullglob; local _w=("$WHEEL_DIR"/myclickup-*.whl); shopt -u nullglob
  if [[ ${#_w[@]} -eq 0 ]]; then
    skip "no vendored wheel in sandbox_templates/wheels/ — myclickup is not vendored on this machine, nothing to check"
    return 0
  fi
  src="$(resolve_src)"
  ver="$(src_version "$src")"
  whl="$(vendored_wheel)"

  case "$whl" in
    *"myclickup-${ver}-"*) : ;;
    # Say what to DO. This check can sit red for days across unrelated work, and
    # a failure nobody knows how to clear gets muted rather than fixed.
    *) die "MISMATCH: $(basename "$whl") vs source version $ver
       re-vendor:  just vendor-myclickup
       then bake:  just build   (the wheel is baked into the image, so the
                   build context going green does NOT mean running containers
                   have the new version — recreate them too)" ;;
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
