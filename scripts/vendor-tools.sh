#!/usr/bin/env bash
# =============================================================================
# vendor-tools.sh — consume the depot channel into sandbox_templates/
# =============================================================================
#
# Part B step 8 of myclickup work/0016 / ADR-0014. Replaces `vendor-myclickup`
# and the myconv leg of `sync-skills-from-conventions.sh` — but NOT until Part B
# step 10 passes. Until then all three coexist deliberately (plan §7, dual-running
# window): the channel is additive, and rollback is "keep using the old scripts".
#
# WHAT THIS IS. One door for every artifact that enters the image. The channel
# publishes `manifest.toml` (versions + sha256 + source commits) alongside a
# `dist/` tree; this script verifies those hashes, mirrors the payloads into
# `sandbox_templates/`, and records what it took in `sandbox_templates/VENDORED.lock`.
#
# WHY THIS IS SECURITY-SENSITIVE. Everything it copies is baked into the image
# (the wheel) or converged into every profile (the skills). A bug here puts
# unverified content inside the sandbox boundary, which is why the hash gate runs
# over EVERY artifact before ANY file is copied — a partial mirror that fails
# halfway is a half-updated image with no record of which half.
#
# WHERE THE CHANNEL IS (three states, three outcomes — plan §5.4.6):
#   $DEPOT_DIR
#   .depot-dir.local            (gitignored, one line; same parser as the two
#                                member pointers)
#   nothing configured          -> SKIP, exit 0   (--check only; ordinary)
#   configured, target missing  -> FAIL, exit 1   (broken pointer, never ordinary)
#   configured and present      -> proceed
#
# There is deliberately NO guessed fallback path, for the reason recorded in
# vendor-myclickup.sh: a guess collapses "never configured" and "moved away" into
# the same output, and the collapsed state is the silent one. That is not
# hypothetical here — it is what made the 2026-08-14 depot move invisible to both
# existing monitors while a real three-release wheel drift went green.
#
# ONE HASH IMPLEMENTATION, NOT TWO. Tree identity comes from the channel's own
# `bin/dirhash.py`, invoked off the channel path. A bash reimplementation would be
# a new cross-repo boundary of exactly the kind this plan exists to delete
# (myclickup work/0016 review-reply §5).
#
# THE ONE PYTHON DEPENDENCY IS DELIBERATE AND BOUNDED. The manifest is TOML, so
# it is read by `python3 -m tomllib` in a single extraction point that emits flat
# TAB-separated lines; everything downstream is bash + coreutils. That is the
# opposite of hand-rolling a TOML parser in awk, which would be a second parser
# of a security-relevant file. `VENDORED.lock` itself is NOT TOML for the same
# reason — flat `artifact version sha256 source_commit` lines, awk-readable.
#
# THE LOCK IS TRACKED, AND IT IS THE ONLY PUBLIC RECORD OF A BUILD'S CONTENTS.
# The wheel (.gitignore:50) and skills/myclickup/ (:51) are both ignored because
# this repo is public and myclickup is private. So `sandbox_templates/VENDORED.lock`
# is the only committed evidence of what an image contained — a genuine gain over
# UPSTREAM.md, which covered half of it. It is a FILE at the templates root, so
# `converge_skills` (which iterates directories) never carries it into a profile.
# =============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

TEMPLATES="$REPO_ROOT/sandbox_templates"
WHEEL_DIR="$TEMPLATES/wheels"
LOCK="$TEMPLATES/VENDORED.lock"

die()  { printf 'vendor-tools: %s\n' "$*" >&2; exit 1; }
# info goes to STDERR, and that is load-bearing rather than stylistic:
# `verify_all` returns the flat manifest table on stdout, so any progress line
# written to stdout is captured into the table by command substitution. When it
# was `printf` to stdout the verified-hash lines vanished from the terminal and
# reappeared as bogus artifact rows, which the case statements below then skipped
# in silence — a half-consumed channel that reports success. Locked by
# vendor-tools.test.sh.
info() { printf '  %s\n' "$*" >&2; }
ok()   { printf '\033[0;32m[ OK ]\033[0m  vendor-tools: %s\n' "$*"; }
skip() { printf '\033[1;35m[SKIP]\033[0m  vendor-tools: %s\n' "$*"; }

# --- where the channel is ----------------------------------------------------
# Same two-source, comment-tolerant parser the member pointers use. It is awk
# rather than `head -n1` because the pointer files carry comment headers, and
# reading the comment AS the path is a bug this repo has already shipped once.
channel_candidate() {
  local candidate=""
  if [[ -n "${DEPOT_DIR:-}" ]]; then
    candidate="$DEPOT_DIR"
  elif [[ -f "$REPO_ROOT/.depot-dir.local" ]]; then
    candidate="$(awk 'NF && $0 !~ /^[[:space:]]*#/ { print; exit }' \
                   "$REPO_ROOT/.depot-dir.local" | tr -d '\r')"
  fi
  # shellcheck disable=SC2088  # deliberate: expand a leading ~ ourselves
  case "$candidate" in "~/"*) candidate="$HOME/${candidate#\~/}" ;; esac
  printf '%s' "$candidate"
}

# Quoted back in every failure so a broken pointer says WHERE to fix it.
channel_origin() {
  if [[ -n "${DEPOT_DIR:-}" ]]; then
    printf '$DEPOT_DIR'
  else
    printf '%s' "$REPO_ROOT/.depot-dir.local"
  fi
}

resolve_channel() {
  local candidate
  candidate="$(channel_candidate)"
  [[ -n "$candidate" ]] || die "channel location unknown. Set one of:
    DEPOT_DIR=/path/to/depot scripts/vendor-tools.sh
    echo /path/to/depot > $REPO_ROOT/.depot-dir.local   (gitignored)"
  [[ -d "$candidate" ]] || die "configured channel root is absent (from $(channel_origin)): $candidate
       the pointer names a path that does not exist — repoint it, do not delete
       it: an empty pointer stands down silently and stops watching the boundary"
  [[ -f "$candidate/manifest.toml" ]] || die "not a channel root (no manifest.toml, from $(channel_origin)): $candidate"
  (cd "$candidate" && pwd)
}

# --- the single manifest extraction point ------------------------------------
# Emits `artifact<TAB>key<TAB>value`. Anything the manifest gains that this does
# not know about is ignored here and caught by the schema guard below, never
# silently half-consumed.
manifest_flat() {
  local root="$1"
  python3 - "$root/manifest.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
schema = doc.get("schema")
if schema != 1:
    sys.exit(f"manifest schema {schema!r} is not 1 — this script was written "
             f"against schema 1; read the channel's ADR before widening it")
for name, art in sorted(doc.get("artifact", {}).items()):
    for key, val in sorted(art.items()):
        if isinstance(val, (str, int)):
            print(f"{name}\t{key}\t{val}")
PY
}

# Look one value up out of the flat table. Absent is empty, never an error —
# callers decide whether absence is fatal, because it differs per artifact kind.
mf() { awk -F'\t' -v a="$2" -v k="$3" '$1==a && $2==k {print $3; exit}' <<<"$1"; }

# --- path safety -------------------------------------------------------------
# The manifest is machine-generated, but it names paths that this script then
# writes FROM, and it crosses a repo boundary. A `../` escaping the channel root
# would read outside it; refuse rather than trust the producer's generator.
assert_inside() {
  local root="$1" rel="$2" what="$3"
  case "$rel" in
    /*|*..*) die "manifest $what path escapes the channel root, refusing: $rel" ;;
  esac
  [[ -e "$root/$rel" ]] || die "manifest names a $what that is not in the channel: $rel"
}

sha_of() { sha256sum "$1" | awk '{print $1}'; }

tree_hash() {
  local root="$1" target="$2"
  [[ -f "$root/bin/dirhash.py" ]] || die "channel has no bin/dirhash.py — cannot verify a tree
       artifact without reimplementing the channel's hash, which this script will not do"
  python3 "$root/bin/dirhash.py" "$root/$target" | awk '{print $NF}'
}

# --- verify EVERY artifact before copying ANY --------------------------------
# Returns the flat manifest on stdout so the caller does not re-read it. Any
# mismatch is fatal here, before a single file has moved.
verify_all() {
  local root="$1" flat art kind rel want got
  flat="$(manifest_flat "$root")"
  [[ -n "$flat" ]] || die "manifest declares no artifacts: $root/manifest.toml"

  while read -r art; do
    kind="$(mf "$flat" "$art" kind)"
    case "$kind" in
      wheel+skill)
        for pair in "wheel wheel_sha256" "skill skill_sha256"; do
          set -- $pair
          rel="$(mf "$flat" "$art" "$1")"; want="$(mf "$flat" "$art" "$2")"
          [[ -n "$rel" && -n "$want" ]] || die "$art: manifest is missing $1/$2"
          assert_inside "$root" "$rel" "$1"
          got="$(sha_of "$root/$rel")"
          [[ "$got" == "$want" ]] || die "HASH MISMATCH $art/$1
       manifest: $want
       actual:   $got
       the channel's own copy does not match what it published — this is a
       channel-side fault, NOT something to clear by re-vendoring here.
       Run \`just verify\` at the channel root."
          info "verified $art/$1  ${want:0:12}…"
        done
        ;;
      plugin)
        rel="$(mf "$flat" "$art" tree)"; want="$(mf "$flat" "$art" tree_sha256)"
        [[ -n "$rel" && -n "$want" ]] || die "$art: manifest is missing tree/tree_sha256"
        assert_inside "$root" "$rel" tree
        got="$(tree_hash "$root" "$rel")"
        [[ "$got" == "$want" ]] || die "HASH MISMATCH $art/tree
       manifest: $want
       actual:   $got
       computed by the channel's own bin/dirhash.py, so this is a channel-side
       fault. Run \`just verify\` at the channel root."
        info "verified $art/tree  ${want:0:12}…"
        ;;
      "") die "$art: manifest entry has no kind" ;;
      *)  die "$art: unknown artifact kind '$kind' — this script mirrors
       wheel+skill and plugin only. A new kind must be taught here explicitly
       rather than skipped, or it would enter the image unverified." ;;
    esac
  done < <(cut -f1 <<<"$flat" | sort -u)

  printf '%s' "$flat"
}

# --- lock --------------------------------------------------------------------
# Flat, sorted, four fields: `artifact version sha256 source_commit`. A wheel+skill
# artifact contributes two lines (`<name>.wheel`, `<name>.skill`) so the one-line
# one-hash shape survives — awk still reads it, and the two halves of a pair can
# drift independently, which is exactly what ADR-0006 wants visible.
write_lock() {
  local flat="$1" root="$2" art kind ver commit tmp
  tmp="$(mktemp)"
  {
    printf '# Generated by scripts/vendor-tools.sh — do not hand-edit.\n'
    printf '# What this image was built from. Fields: artifact version sha256 source_commit\n'
    printf '# Channel: manifest.toml consumed from the depot channel root (ADR-0014).\n'
    while read -r art; do
      kind="$(mf "$flat" "$art" kind)"
      ver="$(mf "$flat" "$art" version)"
      commit="$(mf "$flat" "$art" source_commit)"
      case "$kind" in
        wheel+skill)
          printf '%s.wheel %s %s %s\n' "$art" "$ver" "$(mf "$flat" "$art" wheel_sha256)" "$commit"
          printf '%s.skill %s %s %s\n' "$art" "$ver" "$(mf "$flat" "$art" skill_sha256)" "$commit"
          ;;
        plugin)
          printf '%s.tree %s %s %s\n' "$art" "$ver" "$(mf "$flat" "$art" tree_sha256)" "$commit"
          ;;
        # Same assertion as the mirror loop: an artifact that reached the lock
        # without a known kind means the table is polluted, and a lock missing a
        # row is worse than no lock — it reads as a complete record.
        *) die "internal: unvalidated artifact '$art' (kind '$kind') reached the lock" ;;
      esac
    done < <(cut -f1 <<<"$flat" | sort -u)
  } > "$tmp"
  # Header lines first, payload sorted — a stable file so a lock diff shows a
  # real change and never a reordering.
  { grep '^#' "$tmp"; grep -v '^#' "$tmp" | sort; } > "$LOCK"
  rm -f "$tmp"
}

# --- vendor ------------------------------------------------------------------
do_vendor() {
  local dry="${1:-}" root flat art kind rel ver

  root="$(resolve_channel)"
  info "channel: $root"

  flat="$(verify_all "$root")"

  if [[ "$dry" == "--dry-run" ]]; then
    printf '\nwould mirror:\n'
    while read -r art; do
      kind="$(mf "$flat" "$art" kind)"; ver="$(mf "$flat" "$art" version)"
      case "$kind" in
        wheel+skill)
          printf '  %-12s %-8s wheel -> sandbox_templates/wheels/\n' "$art" "$ver"
          printf '  %-12s %-8s skill -> sandbox_templates/skills/%s/SKILL.md\n' "" "" "$art"
          ;;
        plugin)
          printf '  %-12s %-8s tree  -> sandbox_templates/skills/%s/\n' "$art" "$ver" "$art"
          ;;
      esac
    done < <(cut -f1 <<<"$flat" | sort -u)
    printf '\nwould write: %s\n' "${LOCK#"$REPO_ROOT"/}"
    printf 'nothing was copied (--dry-run)\n'
    return 0
  fi

  # Past this line every hash has already been checked. Mirror.
  while read -r art; do
    kind="$(mf "$flat" "$art" kind)"
    case "$kind" in
      wheel+skill)
        mkdir -p "$WHEEL_DIR" "$TEMPLATES/skills/$art"
        # rm -f before cp is load-bearing: two wheels in this directory is a
        # deliberate BUILD REFUSAL (Dockerfile), not a pick-one. Leaving the old
        # version beside the new one turns a version bump into a failed build.
        rm -f "$WHEEL_DIR"/"$art"-*.whl
        rel="$(mf "$flat" "$art" wheel)"; cp "$root/$rel" "$WHEEL_DIR/"
        rel="$(mf "$flat" "$art" skill)"; cp "$root/$rel" "$TEMPLATES/skills/$art/SKILL.md"
        ;;
      plugin)
        # delete-then-copy, not a merge: a file deleted upstream must vanish here,
        # which is the same rule ADR-0005 enforces for skill convergence and the
        # same failure (phantom copies surviving releases) it exists to prevent.
        rel="$(mf "$flat" "$art" tree)"
        rm -rf "${TEMPLATES:?}/skills/$art"
        mkdir -p "$TEMPLATES/skills/$art"
        cp -R "$root/$rel/." "$TEMPLATES/skills/$art/"
        ;;
      # verify_all has validated every kind, so reaching here means the artifact
      # list this loop walks disagrees with the one it validated — i.e. the flat
      # table is polluted. Assert rather than skip: a silent skip here is a
      # half-mirrored channel reporting success.
      *) die "internal: unvalidated artifact '$art' (kind '$kind') reached the mirror" ;;
    esac
    info "mirrored $art ($(mf "$flat" "$art" version))"
  done < <(cut -f1 <<<"$flat" | sort -u)

  write_lock "$flat" "$root"
  ok "vendored from channel; wrote ${LOCK#"$REPO_ROOT"/}"
  printf '\nNext: scripts/profile.sh build   (the image is not rebuilt by `up`)\n'
  printf 'Then: scripts/profile.sh <p> recreate   (per profile)\n'
}

# --- check -------------------------------------------------------------------
# Is what we consumed still what the channel publishes? Compares VENDORED.lock
# against a freshly hashed manifest. This is the drift half; the content half
# (extracted wheel vs member checkout) stays in vendor-check, per plan §5.4.5 —
# hash alone would move a security-critical verification from the consumer to
# trusting the producer's gate.
do_check() {
  local cand root flat expected actual

  cand="$(channel_candidate)"
  if [[ -z "$cand" ]]; then
    skip "no depot channel configured — channel drift NOT checked.
       set DEPOT_DIR, or: echo /path/to/depot > .depot-dir.local"
    return 0
  fi
  root="$(resolve_channel)"

  if [[ ! -f "$LOCK" ]]; then
    skip "no VENDORED.lock — nothing has been vendored from the channel on this
       machine yet, so there is nothing to compare (run: just vendor-tools)"
    return 0
  fi

  flat="$(verify_all "$root")"
  expected="$(mktemp)"; actual="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$expected' '$actual'" EXIT

  LOCK="$expected" write_lock "$flat" "$root"
  grep -v '^#' "$expected" | sort > "$actual"
  grep -v '^#' "$LOCK"     | sort > "$expected"

  if ! diff -u "$expected" "$actual" > /dev/null; then
    printf 'vendor-tools --check: DRIFT — the channel has moved since the last vendor\n\n'
    diff -u --label 'VENDORED.lock (consumed)' --label 'manifest.toml (published)' \
         "$expected" "$actual" || true
    die "re-vendor:  just vendor-tools
       then bake:  just build   (the wheel is baked into the image, so a green
                   check does NOT mean running containers have the new version —
                   recreate them too)"
  fi
  ok "VENDORED.lock matches the channel manifest ($(grep -vc '^#' "$LOCK") artifact rows)"
}

case "${1:-vendor}" in
  vendor)         do_vendor ;;
  --dry-run)      do_vendor --dry-run ;;
  --check|check)  do_check ;;
  *) die "unknown argument '$1' (want: no args, --dry-run, or --check)" ;;
esac
