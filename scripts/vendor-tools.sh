#!/usr/bin/env bash
# =============================================================================
# vendor-tools.sh — consume the depot channel into sandbox_templates/
# =============================================================================
#
# Part B of myclickup work/0016 / ADR-0014. REPLACED `vendor-myclickup.sh` and
# `sync-skills-from-conventions.sh`, both retired at step 11 on 2026-08-16 after
# step 10 passed — a cutover on evidence (a zero content diff between the two
# mechanisms over the same source), not on trust. Rollback is `git revert`, not
# a fallback path kept alive here.
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
# There is deliberately NO guessed fallback path, for the reason the retired
# vendor-myclickup.sh recorded before it: a guess collapses "never configured" and "moved away" into
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
# The wheel and skills/myclickup/ are both gitignored because this repo is public
# and myclickup is private. So `sandbox_templates/VENDORED.lock`
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
        elif isinstance(val, list):
            for item in val:
                print(f"{name}\t{key}[]\t{item}")
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

# --- content verification (plan §5.4.5 — hash PLUS content, never hash alone) -
#
# A hash proves an artifact did not change in transit. It CANNOT prove the wheel
# matches the `source_commit` it claims. Dropping the content diff for a hash
# would move a security-critical verification from this consumer to trusting the
# producer's gate — a transfer of trust dressed as a simplification. So: hash
# always (above), content additionally whenever the member checkout is reachable,
# and hash-only stated as such when it is not.
#
# Member checkouts resolve through the SAME pointers the legacy scripts use, so
# there is one machine-specific fact per repo and not two. Each source_repo needs
# a line here; a new one that is not listed is reported, never silently skipped.
member_pointer() { # <source_repo> -> "<env-name> <pointer-file>"
  case "$1" in
    myclickup)            printf 'MYCLICKUP_DIR .myclickup-dir.local' ;;
    agentic-conventions)  printf 'CONVENTIONS_DIR .conventions-dir.local' ;;
    *)                    printf '' ;;
  esac
}

member_dir() { # <source_repo> -> path or empty
  local spec env_name ptr val
  spec="$(member_pointer "$1")"; [[ -n "$spec" ]] || return 0
  read -r env_name ptr <<<"$spec"
  val="$(eval "printf '%s' \"\${$env_name:-}\"")"
  if [[ -z "$val" && -f "$REPO_ROOT/$ptr" ]]; then
    val="$(awk 'NF && $0 !~ /^[[:space:]]*#/ { print; exit }' "$REPO_ROOT/$ptr" | tr -d '\r')"
  fi
  case "$val" in "~/"*) val="$HOME/${val#\~/}" ;; esac
  printf '%s' "$val"
}

# Extract <commit>:<path> from a member checkout. The vendored copy tracks the
# PUBLISHED commit, not the member's HEAD — diffing against HEAD would report
# drift every time the member moves ahead of the channel, which is an ordinary
# state and not a fault. Comparing against the published commit is the only way
# the content check answers the question it claims to.
member_subtree() { # <member> <commit> <path> <dest>
  git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null || return 1
  mkdir -p "$4"
  git -C "$1" archive "$2" -- "$3" 2>/dev/null | tar -x -C "$4" 2>/dev/null || return 1
}

content_check() { # <flat>
  local flat="$1" art kind repo commit member tmp checked=0 hashonly=0

  while read -r art; do
    kind="$(mf "$flat" "$art" kind)"
    repo="$(mf "$flat" "$art" source_repo)"
    commit="$(mf "$flat" "$art" source_commit)"

    if [[ -z "$(member_pointer "$repo")" ]]; then
      info "content: $art — source_repo '$repo' has no pointer mapping in this
       script, so its content cannot be checked. Add a member_pointer line."
      hashonly=$((hashonly+1)); continue
    fi
    member="$(member_dir "$repo")"
    if [[ -z "$member" ]]; then
      info "content: $art — no $repo checkout configured, HASH-ONLY (content NOT verified)"
      hashonly=$((hashonly+1)); continue
    fi
    # Configured-but-missing is the broken-pointer state and fails here too. A
    # pointer that names a path which no longer exists is not "not configured".
    [[ -d "$member" ]] || die "configured $repo checkout is absent: $member
       repoint it, do not delete it — an empty pointer stands down silently"

    tmp="$(mktemp -d)"
    if ! member_subtree "$member" "$commit" . "$tmp"; then
      rm -rf "$tmp"
      info "content: $art — $repo has no commit $commit (unfetched?), HASH-ONLY"
      hashonly=$((hashonly+1)); continue
    fi

    case "$kind" in
      wheel+skill)
        local whl ext
        shopt -s nullglob; local _w=("$WHEEL_DIR"/"$art"-*.whl); shopt -u nullglob
        [[ ${#_w[@]} -eq 1 ]] || die "expected exactly 1 vendored $art wheel, found ${#_w[@]}"
        whl="${_w[0]}"; ext="$tmp/.extracted"
        python3 -m zipfile -e "$whl" "$ext"
        diff -r -x '__pycache__' -x '*.pyc' "$tmp/src/$art" "$ext/$art" >/dev/null \
          || { rm -rf "$tmp"; die "CONTENT DRIFT: vendored $art wheel != $repo@${commit:0:8}:src/$art
       the wheel does not match the source commit the manifest claims. This is
       NOT cleared by re-vendoring — the channel published a wheel that
       disagrees with its own source. Run \`just verify\` at the channel root."; }
        diff -q "$tmp/packaging/sandbox/SKILL.md" "$TEMPLATES/skills/$art/SKILL.md" >/dev/null \
          || { rm -rf "$tmp"; die "CONTENT DRIFT: vendored $art skill != $repo@${commit:0:8}"; }
        ;;
      plugin)
        diff -r "$tmp/plugins/$art" "$TEMPLATES/skills/$art" >/dev/null \
          || { rm -rf "$tmp"; die "CONTENT DRIFT: vendored $art tree != $repo@${commit:0:8}:plugins/$art"; }
        ;;
    esac
    rm -rf "$tmp"
    info "content: $art matches $repo@${commit:0:8} (extracted, not hashed)"
    checked=$((checked+1))
  done < <(cut -f1 <<<"$flat" | sort -u)

  # Say what was NOT covered on the closing line. A summary that reports only
  # what passed reads as full coverage; this repo has already been burned once by
  # a green line printed over a check that never ran.
  if [[ "$hashonly" -gt 0 ]]; then
    printf 'content: %d verified against source, %d HASH-ONLY (a skip is not a pass)\n' \
      "$checked" "$hashonly"
  else
    printf 'content: %d verified against source, 0 hash-only\n' "$checked"
  fi
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
  content_check "$flat"
}

# --- permissions (plan §5.4.7) -----------------------------------------------
#
# INFORMATIONAL AND REPORT-ONLY. It never edits claude-settings.json, and that is
# a hard rule rather than a default: that file is on this repo's security-
# sensitive list, so a machine proposing an edit is the most it may ever do.
#
# WHAT IT CANNOT SEE, stated up front because a permissions check that implies
# more coverage than it has is worse than none. This compares the manifest's
# generated proposal against the TEMPLATE FILE. It cannot see:
#   * what a running profile has — settings seeding is create-only, so a template
#     edit reaches nothing until `profile.sh <p> reset-settings`; the block this
#     compares sat undeployed on all three profiles for five days in 2026-08.
#   * what the RUNTIME does with a command on none of the lists. Under
#     defaultMode:auto that is decided by a classifier, not prompted by default —
#     measured 2026-08-15. Which is why proposed_ask exists and why a write being
#     merely ABSENT from allow is a gap, not a policy.
do_permissions() {
  local root; root="$(resolve_channel)"
  python3 - "$root/manifest.toml" "$TEMPLATES/claude/claude-settings.json" <<'PY'
import json, re, sys, tomllib

with open(sys.argv[1], "rb") as fh:
    manifest = tomllib.load(fh)
with open(sys.argv[2]) as fh:
    perms = json.load(fh)["permissions"]

def cmd(pattern):
    """The command prefix a Bash(...) pattern denotes, or None."""
    m = re.fullmatch(r"Bash\((.*?):?\*?\)", pattern)
    return m.group(1) if m else None

def covers(deployed, proposed):
    """Claude Code's Bash matcher is a string prefix on the command, so a
    deployed `myclickup status` pattern covers a proposed `myclickup statuses`.
    That over-match is benign here (both reads) and must not read as a miss —
    a check that cries wolf on its first run is a check that gets ignored."""
    d, p = cmd(deployed), cmd(proposed)
    return d is not None and p is not None and p.startswith(d)

deployed = {k: perms.get(k, []) for k in ("allow", "ask", "deny")}
rc_gaps = []

for name, art in sorted(manifest.get("artifact", {}).items()):
    proposals = {k: art.get(f"proposed_{k}", []) for k in ("allow", "ask", "deny")}
    if not any(proposals.values()):
        continue
    print(f"\n{name} {art.get('version','?')} — manifest proposal vs sandbox_templates/claude/claude-settings.json")
    for kind, wanted in proposals.items():
        # A write may be gated by `ask` OR by the stronger `deny`; either counts.
        pool = deployed[kind] + (deployed["deny"] if kind == "ask" else [])
        missing, via_prefix = [], []
        for w in wanted:
            if w in pool:
                continue
            hit = next((d for d in pool if covers(d, w)), None)
            (via_prefix if hit else missing).append((w, hit))
        print(f"  {kind:5} proposed {len(wanted):2}  "
              f"exact {len(wanted)-len(missing)-len(via_prefix):2}  "
              f"by-prefix {len(via_prefix):2}  MISSING {len(missing):2}")
        for w, hit in via_prefix:
            print(f"        covered by prefix: {w}  <-  {hit}")
        for w, _ in missing:
            print(f"        MISSING: {w}")
            if kind in ("ask", "deny"):
                rc_gaps.append((name, kind, w))

    # The deployed side may legitimately carry entries the manifest does not
    # propose; report them rather than treating the proposal as exhaustive.
    tool = name
    extra = [e for e in deployed["allow"] + deployed["ask"] + deployed["deny"]
             if (c := cmd(e)) and c.split()[0] == tool
             and e not in sum(proposals.values(), [])]
    for e in extra:
        print(f"        deployed but not proposed: {e}")

print("\nInformational only — nothing was changed. claude-settings.json is on the")
print("security-sensitive list; an edit here is a human's, with `verify` + `audit`.")
if rc_gaps:
    print(f"\n{len(rc_gaps)} WRITE-SURFACE GAP(S): a write on neither `ask` nor `deny` is")
    print("not gated by absence — under defaultMode:auto a classifier decides.")
print("\nThis compares the TEMPLATE, not any running profile: seeding is create-only,")
print("so run `scripts/profile.sh <p> reset-settings` to deploy a template change.")
PY
}

case "${1:-vendor}" in
  vendor)         do_vendor ;;
  --dry-run)      do_vendor --dry-run ;;
  --check|check)  do_check ;;
  --permissions)  do_permissions ;;
  *) die "unknown argument '$1' (want: no args, --dry-run, --check, or --permissions)" ;;
esac
