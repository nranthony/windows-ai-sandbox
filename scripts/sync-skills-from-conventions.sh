#!/usr/bin/env bash
# =============================================================================
# sync-skills-from-conventions.sh — pull shared skills from agentic-conventions
# =============================================================================
# Refreshes this repo's VENDORED skill templates (sandbox_templates/skills/)
# from the upstream agentic-conventions repo. Vendoring, not linking: the
# content travels, the path does not. A symlink would encode a personal path
# into the tree, break on Windows/zip-export checkouts, and fail to resolve
# from inside a container — same reasoning as sync-agent-files.sh.
#
# This script is a DEVELOPER action, not part of any lifecycle. It must never
# run during a container build, `up`, or `rebuild`: builds stay offline,
# deterministic, and independent of whether agentic-conventions is checked out
# on this machine.
#
# Usage:
#   scripts/sync-skills-from-conventions.sh [--dry-run] [<skill> ...]
#
#   --dry-run   report what would change; write nothing
#   <skill>     restrict to named skills (default: every upstream skill)
#
# Source location resolution, in order:
#   1. $CONVENTIONS_DIR
#   2. .conventions-dir.local at this repo's root (gitignored, one line)
#   3. fail with instructions
#
# AFTER SYNCING: this only updates the committed TEMPLATE tree. Live profiles
# are unaffected until you re-seed them, because ensure_state's skill loop is
# create-only (profile.sh) — it seeds a skill that is missing but never
# overwrites one that exists, so a profile keeps any local customisation:
#
#   NEW skill      -> lands in each profile on its next `profile.sh <p> up`
#   EDITED skill   -> needs `scripts/profile.sh <p> reset-skills` (backs up old)
#
# Sandbox-native skills (audit-sandbox, web-read) have no upstream counterpart
# and are never touched by this script.
#
# Kept in the bash-3.2/POSIX-awk subset for portability to the sibling macolima
# repo (no bash-4 features).
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_ROOT="$REPO_ROOT/sandbox_templates/skills"
POINTER_FILE="$REPO_ROOT/.conventions-dir.local"
MANIFEST="$DEST_ROOT/UPSTREAM.md"

# Upstream's genericised "for other repos" surface — deliberately NOT its live
# .claude/skills/, which may carry conventions-repo-specific wording.
SRC_SUBPATH="templates/.claude/skills"

info() { printf '\033[0;36m[INFO]\033[0m  %s\n' "$*"; }
ok()   { printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
fail() { printf '\033[0;31m[FAIL]\033[0m  %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
dry=0
want=""
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    -h|--help) sed -n '5,/^# =====/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        fail "unknown flag: $a" ;;
    *)         want="$want $a" ;;
  esac
done

# ---------------------------------------------------------------------------
# Resolve the upstream checkout (the one machine-specific fact)
# ---------------------------------------------------------------------------
src_root=""
src_origin=""
if [[ -n "${CONVENTIONS_DIR:-}" ]]; then
  src_root="$CONVENTIONS_DIR"
  src_origin="\$CONVENTIONS_DIR"
elif [[ -f "$POINTER_FILE" ]]; then
  # First non-blank, non-comment line.
  src_root="$(awk 'NF && $0 !~ /^[[:space:]]*#/ { print; exit }' "$POINTER_FILE")"
  src_origin="$POINTER_FILE"
fi

if [[ -z "$src_root" ]]; then
  fail "agentic-conventions location unknown. Set one of:
    CONVENTIONS_DIR=/path/to/agentic-conventions scripts/sync-skills-from-conventions.sh
    echo /path/to/agentic-conventions > $POINTER_FILE   (gitignored)"
fi

# Expand a leading ~ (a pointer file is hand-written; env vars are not expanded
# inside it, so do the one case that actually shows up).
case "$src_root" in
  "~/"*) src_root="$HOME/${src_root#\~/}" ;;
esac

[[ -d "$src_root" ]] || fail "conventions dir does not exist (from $src_origin): $src_root"
src_root="$(cd "$src_root" && pwd)"
SRC_ROOT="$src_root/$SRC_SUBPATH"
[[ -d "$SRC_ROOT" ]] || fail "not an agentic-conventions checkout (no $SRC_SUBPATH): $src_root"

[[ -d "$DEST_ROOT" ]] || fail "vendored skills dir missing: $DEST_ROOT"

# Provenance: record what we synced from, so a stale vendored copy is
# diagnosable without guessing which upstream commit it came from.
src_rev="$(git -C "$src_root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
src_dirty=""
if ! git -C "$src_root" diff --quiet HEAD 2>/dev/null; then
  src_dirty=" (dirty worktree)"
  warn "upstream checkout has uncommitted changes — vendoring them anyway"
fi

info "source: $src_root @ $src_rev$src_dirty  (via $src_origin)"
info "dest:   $DEST_ROOT"
[[ "$dry" == "1" ]] && info "dry-run: no files will be written"

# ---------------------------------------------------------------------------
# Select skills
# ---------------------------------------------------------------------------
skills=""
if [[ -n "$want" ]]; then
  for name in $want; do
    [[ -d "$SRC_ROOT/$name" ]] || fail "no such upstream skill: $name (looked in $SRC_ROOT)"
    skills="$skills $name"
  done
else
  for d in "$SRC_ROOT"/*/; do
    [[ -d "$d" ]] || continue
    skills="$skills $(basename "$d")"
  done
fi
[[ -n "$skills" ]] || fail "no skills found in $SRC_ROOT"

# ---------------------------------------------------------------------------
# Sync
# ---------------------------------------------------------------------------
n_new=0; n_upd=0; n_same=0
synced=""

for name in $skills; do
  src="$SRC_ROOT/$name"
  dst="$DEST_ROOT/$name"

  # A SKILL.md is what makes a directory a skill; refuse anything else rather
  # than vendoring a stray folder into every profile's ~/.claude/skills/.
  [[ -f "$src/SKILL.md" ]] || { warn "skipping '$name': no SKILL.md"; continue; }

  # Stage the copy so per-surface variants/ (claude.ai bodies — Claude
  # Code-incompatible) never reach the container, and so a mid-copy failure
  # cannot leave a half-written skill in the committed tree.
  stage="$(mktemp -d)"
  cp -R "$src" "$stage/$name"
  rm -rf "$stage/$name/variants"

  if [[ ! -d "$dst" ]]; then
    status="new"
    n_new=$((n_new + 1))
  elif diff -rq "$stage/$name" "$dst" >/dev/null 2>&1; then
    status="unchanged"
    n_same=$((n_same + 1))
  else
    status="updated"
    n_upd=$((n_upd + 1))
  fi

  if [[ "$status" != "unchanged" && "$dry" == "1" ]]; then
    printf '  %-10s %s\n' "$status" "$name"
    diff -rq "$dst" "$stage/$name" 2>/dev/null | sed 's/^/      /' || true
  elif [[ "$status" != "unchanged" ]]; then
    rm -rf "$dst"
    cp -R "$stage/$name" "$dst"
    printf '  %-10s %s\n' "$status" "$name"
  else
    printf '  %-10s %s\n' "$status" "$name"
  fi

  rm -rf "$stage"
  synced="$synced $name"
done

# ---------------------------------------------------------------------------
# Provenance manifest — not a skill dir, so ensure_state's `*/` loop and
# reset-skills both ignore it; it never reaches a container.
#
# Lists every upstream-managed skill (present BOTH upstream and in the vendored
# tree), not just the ones touched this run — otherwise a single-skill sync
# would silently drop the others from the manifest. Skills not re-synced keep
# the rev they were last vendored from.
# ---------------------------------------------------------------------------

# Rev previously recorded for a skill, or "unknown" if it has no row yet.
prev_rev() {
  [[ -f "$MANIFEST" ]] || { printf 'unknown'; return; }
  awk -v n="$1" -F'|' '
    NF >= 4 {
      k = $2; r = $4
      gsub(/[ `]/, "", k); gsub(/[ `]/, "", r)
      if (k == n && r != "") { print r; found = 1; exit }
    }
    END { if (!found) print "unknown" }
  ' "$MANIFEST"
}

if [[ "$dry" != "1" ]]; then
  # Build every row FIRST: the `> "$MANIFEST"` redirect below truncates the file
  # when the group opens, so any prev_rev() lookup made inside it would read an
  # already-empty manifest and report every carried-forward skill as "unknown".
  rows=""
  for d in "$SRC_ROOT"/*/; do
    [[ -d "$d" ]] || continue
    mname="$(basename "$d")"
    # Upstream-managed = present upstream AND vendored here.
    [[ -d "$DEST_ROOT/$mname" ]] || continue
    case " $synced " in
      *" $mname "*) rev="$src_rev" ;;
      *)            rev="$(prev_rev "$mname")" ;;
    esac
    rows="$rows$(printf '| `%s` | `%s/%s/` | `%s` |' "$mname" "$SRC_SUBPATH" "$mname" "$rev")
"
  done

  {
    printf '# Vendored skills — upstream provenance\n\n'
    printf '<!-- GENERATED by scripts/sync-skills-from-conventions.sh — do not hand-edit. -->\n\n'
    printf 'Skills listed here are VENDORED COPIES from the shared `agentic-conventions`\n'
    printf 'repo. Edit them upstream and re-run the sync; a local edit here is silently\n'
    printf 'reverted by the next sync.\n\n'
    printf 'Skills NOT listed here (e.g. `audit-sandbox`, `web-read`) are sandbox-native —\n'
    printf 'this repo is their source of truth and the sync never touches them.\n\n'
    printf '| Skill | Upstream source | Synced from rev |\n'
    printf '|---|---|---|\n'
    printf '%s' "$rows"
    printf '\nRefresh: `just sync-skills` (or `scripts/sync-skills-from-conventions.sh`).\n'
    printf 'Then re-seed live profiles — `ensure_state` seeds only MISSING skills:\n\n'
    printf '```\n'
    printf 'scripts/profile.sh <profile> reset-skills   # overwrite (backs up old)\n'
    printf '```\n'
  } > "$MANIFEST"
fi

echo
if [[ "$dry" == "1" ]]; then
  ok "dry-run: $n_new new, $n_upd updated, $n_same unchanged (nothing written)"
  exit 0
fi

ok "synced: $n_new new, $n_upd updated, $n_same unchanged"

if [[ $((n_new + n_upd)) -gt 0 ]]; then
  echo
  info "template tree updated — live profiles are NOT yet refreshed:"
  [[ $n_new -gt 0 ]] && echo "    new skills land on each profile's next: scripts/profile.sh <p> up"
  [[ $n_upd -gt 0 ]] && echo "    edited skills need:                     scripts/profile.sh <p> reset-skills"
  echo "    then restart claude inside the container to pick them up."
  echo
  info "review + commit the vendored change: git diff sandbox_templates/skills/"
fi
