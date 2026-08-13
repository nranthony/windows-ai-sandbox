#!/usr/bin/env bash
# =============================================================================
# profile-skills.test.sh — converge_skills regression suite (offline)
# =============================================================================
# No docker, no network. Runs the REAL `scripts/profile.sh <p> reset-skills`
# against a throwaway repo root + throwaway HOME, so the dispatch path under
# test is the one `up` uses (ensure_state → converge_skills).
#
# What these assertions are for (ADR-0005): claude-home/skills/ is a DERIVED
# CACHE of sandbox_templates/skills/. Three of the checks below are regression
# locks for defects measured against live profiles:
#
#   * `<name>.bak.<stamp>` left inside the scanned directory is a SECOND LIVE
#     copy. For a skills-dir plugin the backup WINS the name race and the fresh
#     copy reports "✘ Not loaded". Hence: no backups, and stale ones get pruned.
#     (measured in-container 2026-08-10)
#   * a directory this script did NOT seed must survive convergence —
#     `claude plugin init` scaffolds into ~/.claude/skills/<name>/, so a
#     "mirror the template" prune would delete an agent's own plugin.
#     (measured in-container 2026-08-10)
#   * convergence MIRRORS a skill, it does not merge into it: a file deleted
#     inside a skill must vanish from the profile, including at depth and behind
#     a dot-directory. All three live profiles carried phantom skill copies four
#     levels down for three upstream releases. (2026-08-13, section 6)
#
# Usage: bash scripts/profile-skills.test.sh
# =============================================================================
set -uo pipefail

REAL_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/profile.sh"
[[ -f "$REAL_SCRIPT" ]] || { echo "cannot find profile.sh next to this test" >&2; exit 1; }

pass=0; fail=0
ok()   { printf '  \033[0;32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
check(){ if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (want '$2', got '$1')"; fi; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

REPO="$ROOT/repo"
HOME_DIR="$ROOT/home"
TPL="$REPO/sandbox_templates/skills"
DST="$HOME_DIR/.ai-sandbox/profiles/testp/claude-home/skills"

mkdir -p "$REPO/scripts" "$TPL" "$HOME_DIR"
cp "$REAL_SCRIPT" "$REPO/scripts/profile.sh"

# A loose skill and a PLUGIN-shaped skill (no top-level SKILL.md — the myconv
# shape: .claude-plugin/plugin.json + nested skills/*/SKILL.md).
mk_loose() {  # <name> <body>
  mkdir -p "$TPL/$1"
  printf -- "---\nname: %s\ndescription: %s\n---\n" "$1" "$2" > "$TPL/$1/SKILL.md"
}
mk_plugin() { # <name> <version>
  mkdir -p "$TPL/$1/.claude-plugin" "$TPL/$1/skills/inner"
  printf '{"name":"%s","version":"%s"}\n' "$1" "$2" > "$TPL/$1/.claude-plugin/plugin.json"
  printf -- "---\nname: inner\ndescription: inner skill\n---\n" > "$TPL/$1/skills/inner/SKILL.md"
}

run() { # -> stdout+stderr of a reset-skills run
  ( cd "$ROOT" && HOME="$HOME_DIR" SANDBOX_GPU=0 \
      bash "$REPO/scripts/profile.sh" testp reset-skills 2>&1 )
}

echo "-- converge_skills --"

# 1. cold seed
mk_loose alpha "first"
mk_plugin myconv 0.1.0
out="$(run)"
check "$([[ -f "$DST/alpha/SKILL.md" ]] && echo y || echo n)" y "cold run seeds a loose skill"
check "$([[ -f "$DST/myconv/.claude-plugin/plugin.json" ]] && echo y || echo n)" y \
  "cold run seeds a plugin-shaped skill (no top-level SKILL.md required)"
check "$([[ -f "$DST/inner/SKILL.md" ]] && echo y || echo n)" n \
  "nested plugin skills are NOT flattened into the skills dir"
check "$(grep -c 'seeded skill' <<<"$out")" 2 "both seeds are announced"

# 2. idempotence — a second run with no template change says nothing about them
out="$(run)"
check "$(grep -c 'OVERWRITTEN' <<<"$out")" 0 "identical copies are not overwritten"
check "$(grep -c 'seeded skill' <<<"$out")" 0 "identical copies are not re-seeded"

# 3. template edit wins, loudly
mk_loose alpha "second"
out="$(run)"
check "$(grep -c "skill 'alpha' differed" <<<"$out")" 1 "template edit WARNs before overwriting"
check "$(grep -c 'second' "$DST/alpha/SKILL.md")" 1 "template edit reaches the profile"

# 4. local edit is overwritten, and warns
printf 'local hand edit\n' >> "$DST/alpha/SKILL.md"
out="$(run)"
check "$(grep -c "skill 'alpha' differed" <<<"$out")" 1 "local divergence WARNs"
check "$(grep -c 'local hand edit' "$DST/alpha/SKILL.md")" 0 "local divergence is reconciled away"

# 5. a stale backup is pruned and warned about  <-- REGRESSION LOCK
cp -R "$DST/myconv" "$DST/myconv.bak.20260810-120000"
out="$(run)"
check "$([[ -d "$DST/myconv.bak.20260810-120000" ]] && echo y || echo n)" n \
  "*.bak.* is pruned (a plugin backup wins the name race — measured)"
check "$(grep -c 'pruned stale skill backup' <<<"$out")" 1 "backup prune WARNs"
check "$([[ -f "$DST/myconv/.claude-plugin/plugin.json" ]] && echo y || echo n)" y \
  "the live plugin survives the prune"

# 6. a file deleted INSIDE a skill disappears from the profile  <-- REGRESSION LOCK
#    Section 6 covers SKILL-level pruning; this covers pruning WITHIN a skill,
#    which is a different code path and the one that matters for a plugin
#    payload. Shape is taken from the real defect (2026-08-13): the myconv
#    payload carried skill copies at
#    skills/<s>/templates/.claude/skills/<name>/SKILL.md — four levels down,
#    behind a HIDDEN directory. A convergence that copied per-file over the
#    existing tree would leave them in every profile while reporting success,
#    because "this file should not exist" is not a question a copy-forward asks.
#    Depth and the dot-directory are both load-bearing: they are what the
#    `diff -rq` divergence test must see for the rm -rf branch to fire at all.
GHOST="$TPL/myconv/skills/inner/templates/.claude/skills/ghost"
mkdir -p "$GHOST"
printf -- "---\nname: ghost\ndescription: phantom twin\n---\n" > "$GHOST/SKILL.md"
out="$(run)"
DST_GHOST="$DST/myconv/skills/inner/templates/.claude/skills/ghost/SKILL.md"
check "$([[ -f "$DST_GHOST" ]] && echo y || echo n)" y \
  "a nested file added to a skill reaches the profile"
rm -rf "$TPL/myconv/skills/inner/templates"
out="$(run)"
check "$([[ -f "$DST_GHOST" ]] && echo y || echo n)" n \
  "a nested file DELETED from a skill is removed from the profile (not merged over)"
check "$([[ -d "$DST/myconv/skills/inner/templates" ]] && echo y || echo n)" n \
  "the emptied parent directory goes with it"
check "$(grep -c "skill 'myconv' differed" <<<"$out")" 1 \
  "a deletion-only change still registers as divergence"
check "$([[ -f "$DST/myconv/skills/inner/SKILL.md" ]] && echo y || echo n)" y \
  "the rest of the payload survives the wholesale replace"

# 7. a skill dropped from the template is pruned — because we seeded it
rm -rf "$TPL/alpha"
out="$(run)"
check "$([[ -d "$DST/alpha" ]] && echo y || echo n)" n "retired template skill is pruned"
check "$(grep -c "pruned retired skill 'alpha'" <<<"$out")" 1 "retired prune WARNs"

# 8. a directory we never seeded SURVIVES  <-- REGRESSION LOCK
#    (`claude plugin init` scaffolds straight into ~/.claude/skills/)
mkdir -p "$DST/handmade/.claude-plugin"
printf '{"name":"handmade","version":"9.9.9"}\n' > "$DST/handmade/.claude-plugin/plugin.json"
out="$(run)"
check "$([[ -f "$DST/handmade/.claude-plugin/plugin.json" ]] && echo y || echo n)" y \
  "an unmanaged plugin dir is never pruned"
check "$(grep -c "not from the template tree" <<<"$out")" 1 "unmanaged dir is reported, not deleted"

# 9. manifest reflects only what the template owns
check "$(sort "$DST/.sandbox-seeded" 2>/dev/null | tr -d '\n')" "myconv" \
  "manifest lists exactly the template's skills"

# 10. the manifest is a file, not a skill dir (must not be scanned as one)
check "$([[ -f "$DST/.sandbox-seeded" ]] && echo y || echo n)" y "manifest is a dotfile beside the skills"

printf '\n  %d passed, %d failed\n\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
