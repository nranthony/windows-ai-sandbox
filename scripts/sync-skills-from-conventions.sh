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
# are unaffected until the next `up`, which CONVERGES each profile's
# claude-home/skills/ to this tree (ADR-0005 — the template is the source of
# truth, the profile copy is a derived cache):
#
#   NEW skill      -> lands in each profile on its next `profile.sh <p> up`
#   EDITED skill   -> same; the profile copy is replaced, with a WARN
#   REMOVED skill  -> pruned from each profile on its next `up`
#
# `reset-skills` performs the same convergence without touching the container.
# Neither takes a backup: a `<name>.bak.<stamp>` inside claude-home/skills/ is a
# second LIVE copy of the skill it backs up (see converge_skills in profile.sh).
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

# TWO upstream surfaces, both vendored into sandbox_templates/skills/ because
# that is the one directory `converge_skills` seeds from (ADR-0005):
#
#   templates/.claude/skills/<name>/   loose skill  — validated by SKILL.md
#   plugins/<name>/                    PLUGIN       — validated by
#                                      .claude-plugin/plugin.json
#
# A directory under ~/.claude/skills/ holding `.claude-plugin/plugin.json`
# auto-loads as `<name>@skills-dir` with its nested skills namespaced
# (`/<name>:<skill>`). So a plugin needs no separate seeding path — only a
# different validity test, which is why this script carries both.
#
# Deliberately NOT upstream's live `.claude/skills/`, which may carry
# conventions-repo-specific wording; `templates/` and `plugins/` are its
# genericised "for other repos" surfaces.
SRC_SUBPATH="templates/.claude/skills"
SRC_SUBPATH_PLUGINS="plugins"

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
SRC_ROOT_PLUGINS="$src_root/$SRC_SUBPATH_PLUGINS"
[[ -d "$SRC_ROOT" ]] || fail "not an agentic-conventions checkout (no $SRC_SUBPATH): $src_root"

# Which surface a name lives on, and whether it is a valid member of it.
# Plugins win a name collision: a directory carrying plugin.json is a plugin
# even if it also happens to hold a top-level SKILL.md.
surface_root_of() {  # <name> -> upstream dir, or "" if on neither surface
  if [[ -f "$SRC_ROOT_PLUGINS/$1/.claude-plugin/plugin.json" ]]; then
    printf '%s' "$SRC_ROOT_PLUGINS"
  elif [[ -f "$SRC_ROOT/$1/SKILL.md" ]]; then
    printf '%s' "$SRC_ROOT"
  fi
}
surface_subpath_of() {  # <name> -> the subpath to record in UPSTREAM.md
  case "$(surface_root_of "$1")" in
    "$SRC_ROOT_PLUGINS") printf '%s' "$SRC_SUBPATH_PLUGINS" ;;
    "$SRC_ROOT")         printf '%s' "$SRC_SUBPATH" ;;
  esac
}

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
    [[ -n "$(surface_root_of "$name")" ]] \
      || fail "no such upstream skill or plugin: $name
       looked for $SRC_SUBPATH/$name/SKILL.md
              and $SRC_SUBPATH_PLUGINS/$name/.claude-plugin/plugin.json"
    skills="$skills $name"
  done
else
  # DEFAULT = the PLUGIN surface only. Upstream keeps `templates/.claude/skills/`
  # as its adapt-by-hand surface for consumers who want committed loose skills,
  # and deliberately still ships make-plan/wrap-up there — but here they are
  # superseded by the same skills inside the `myconv` plugin, where they are
  # namespaced (`/myconv:make-plan`) and carry a version. Enumerating both
  # surfaces would re-vendor the loose twins on every sync and re-create the
  # duplicate-procedure drift that ADR-0007 upstream exists to remove.
  #
  # An explicit name still resolves on EITHER surface, so
  # `sync-skills-from-conventions.sh make-plan` remains available for a
  # deliberate one-off.
  for d in "$SRC_ROOT_PLUGINS"/*/; do
    [[ -d "$d" ]] || continue
    skills="$skills $(basename "$d")"
  done
  # Name what is being passed over, so the choice stays visible instead of
  # looking like the loose surface was forgotten.
  skipped=""
  for d in "$SRC_ROOT"/*/; do
    [[ -d "$d" ]] || continue
    sname="$(basename "$d")"
    [[ -d "$DEST_ROOT/$sname" ]] && continue
    skipped="$skipped $sname"
  done
  [[ -n "$skipped" ]] && \
    info "not vendored (loose upstream skills superseded by a plugin):$skipped"
fi
[[ -n "$skills" ]] || fail "nothing found in $SRC_ROOT_PLUGINS"

# ---------------------------------------------------------------------------
# Sync
# ---------------------------------------------------------------------------
n_new=0; n_upd=0; n_same=0
synced=""

for name in $skills; do
  # A top-level SKILL.md is what makes a directory a skill; a
  # .claude-plugin/plugin.json is what makes it a plugin. Anything else is a
  # stray folder and is refused rather than vendored into every profile's
  # ~/.claude/skills/. (A plugin has NO top-level SKILL.md — validating on that
  # alone silently skipped the whole plugin surface.)
  src_surface="$(surface_root_of "$name")"
  if [[ -z "$src_surface" ]]; then
    warn "skipping '$name': neither a skill (SKILL.md) nor a plugin (.claude-plugin/plugin.json)"
    continue
  fi
  src="$src_surface/$name"
  dst="$DEST_ROOT/$name"

  # Stage the copy so per-surface variants/ (claude.ai bodies — Claude
  # Code-incompatible) never reach the container, and so a mid-copy failure
  # cannot leave a half-written skill in the committed tree.
  stage="$(mktemp -d)"
  cp -R "$src" "$stage/$name"
  # RECURSIVE on purpose. A loose skill keeps variants/ at its root, but a
  # plugin's live one level deeper (plugins/<p>/skills/<skill>/variants/), so a
  # root-only `rm -rf "$stage/$name/variants"` silently stops stripping the
  # moment the payload becomes a plugin — the guard would lapse, not fail.
  find "$stage/$name" -type d -name variants -prune -exec rm -rf {} + 2>/dev/null || true

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
  # Field positions follow the generated table: | name | kind | source | rev |
  # (leading pipe makes $1 empty). This tracked the 4-column layout before the
  # `kind` column landed; reading the wrong field yields a PATH where a rev
  # belongs, which then gets written back as the provenance.
  awk -v n="$1" -F'|' '
    NF >= 5 {
      k = $2; r = $5
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
  for d in "$SRC_ROOT"/*/ "$SRC_ROOT_PLUGINS"/*/; do
    [[ -d "$d" ]] || continue
    mname="$(basename "$d")"
    # Upstream-managed = a valid member of a surface AND vendored here.
    msub="$(surface_subpath_of "$mname")"
    [[ -n "$msub" ]] || continue
    [[ -d "$DEST_ROOT/$mname" ]] || continue
    case " $synced " in
      *" $mname "*) rev="$src_rev" ;;
      *)            rev="$(prev_rev "$mname")" ;;
    esac
    kind="skill"
    [[ "$msub" == "$SRC_SUBPATH_PLUGINS" ]] && kind="plugin"
    rows="$rows$(printf '| `%s` | %s | `%s/%s/` | `%s` |' "$mname" "$kind" "$msub" "$mname" "$rev")
"
  done

  {
    printf '# Vendored skills — upstream provenance\n\n'
    printf '<!-- GENERATED by scripts/sync-skills-from-conventions.sh — do not hand-edit. -->\n\n'
    printf 'Skills listed here are VENDORED COPIES from the shared `agentic-conventions`\n'
    printf 'repo. Edit them upstream and re-run the sync; a local edit here is silently\n'
    printf 'reverted by the next sync.\n\n'
    printf 'Entries NOT listed here (e.g. `audit-sandbox`, `web-read`) are sandbox-native —\n'
    printf 'this repo is their source of truth and the sync never touches them. Entries\n'
    printf 'vendored from a DIFFERENT upstream (e.g. a tool shipping its own skill beside\n'
    printf 'its wheel) are not listed either; only `agentic-conventions` material is.\n\n'
    printf 'A `plugin` entry carries `.claude-plugin/plugin.json` and loads as\n'
    printf '`<name>@skills-dir`, so its own skills are namespaced `/<name>:<skill>`.\n\n'
    printf '| Name | Kind | Upstream source | Synced from rev |\n'
    printf '|---|---|---|---|\n'
    printf '%s' "$rows"
    printf '\nRefresh: `just sync-skills` (or `scripts/sync-skills-from-conventions.sh`).\n'
    printf 'Live profiles converge to this tree on their next `up` (ADR-0005). To push\n'
    printf 'the change now without touching the container:\n\n'
    printf '```\n'
    printf 'scripts/profile.sh <profile> reset-skills   # converge (no backups kept)\n'
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
  echo "    new AND edited skills land on each profile's next: scripts/profile.sh <p> up"
  echo "    to push now without touching the container:        scripts/profile.sh <p> reset-skills"
  echo "    then restart claude inside the container to pick them up."
  echo
  info "review + commit the vendored change: git diff sandbox_templates/skills/"
fi
