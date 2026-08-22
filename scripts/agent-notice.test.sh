#!/usr/bin/env bash
# =============================================================================
# agent-notice.test.sh — content rules for the managed sandbox-notice
# =============================================================================
# Offline: no docker, no network, no profile state. Reads only the canonical
# block (sandbox_templates/common/agent-notice.md) and the settings template.
#
# WHY THIS SUITE EXISTS
# ---------------------
# The notice is written HERE and deployed by scripts/sync-agent-notice.sh into
# every consumer repo's AGENTS.md and every profile's claude-home/CLAUDE.md.
# That makes it the one file in this repo whose text is read from a filesystem
# where this repo does not exist. Two failure modes follow, and neither is
# visible from inside windows-ai-sandbox, where every path resolves fine:
#
#   1. A REPO-RELATIVE PATH. `scripts/with-egress.sh` shipped in the notice for
#      months. Inside /workspace/numerai/AGENTS.md it resolves to
#      /workspace/numerai/scripts/with-egress.sh, which does not exist — the
#      script lives only in this repo and macolima. Found 2026-08-20 by an
#      outside audit (a consumer repo running /myconv:apply-conventions), not
#      by anything here.
#
#   2. A HOST-SIDE MECHANISM. That same reference was worse than a dead path.
#      The notice's whole purpose is "treat a denial as a human step, do not
#      hunt for a workaround" — and naming a script converts "ask the human"
#      into "run this". The agent then burns turns discovering it has no route:
#      no /var/run/docker.sock and no docker client in the container. A
#      mechanism the agent cannot invoke is an invitation to try, sitting
#      inside the anti-workaround section.
#
# The rule that falls out, and what each half checks:
#   every path must resolve FROM WHERE THE AGENT STANDS  -> relpath rule below
#   name the ask, never the host-side mechanism           -> mechanism rule
#
# Note the first is deliberately NOT "must resolve inside the repo it ships
# in". The notice correctly names /usr/lib/wsl/lib/nvidia-smi, /root/.claude,
# ~/.local/bin and /workspace — none inside any repo, all right, and one of
# them exists specifically to stop an agent concluding "no GPU". Repo
# containment flags all four; frame-of-reference flags none.
# =============================================================================
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
NOTICE="$HERE/sandbox_templates/common/agent-notice.md"
SETTINGS="$HERE/sandbox_templates/claude/claude-settings.json"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf "  ok   %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1  (want '$3', got '$2')"; fi; }

[ -f "$NOTICE" ]   || { printf "  FAIL canonical notice missing: %s\n" "$NOTICE"; exit 1; }
[ -f "$SETTINGS" ] || { printf "  FAIL settings template missing: %s\n" "$SETTINGS"; exit 1; }

# --- the two rules, as functions, so a fixture can be run through them too ---

# A backticked span is a REPO-RELATIVE PATH when it contains a slash, contains
# no whitespace, and does not start with `/` (absolute), `~` (agent home) or
# `*` (glob). The three exclusions are what keep the legitimate forms out:
# absolute container paths, agent-home paths, and `**/credentials`. Whitespace
# is what separates a path from a command list — `git push/pull/fetch/clone`
# and `cargo/go install` carry slashes and are not paths.
relpaths() {
  grep -o '`[^`]*`' "$1" | sed 's/^`//; s/`$//' \
    | grep -v '[[:space:]]' | grep '/' | grep -v '^[/~*]' | sort -u
}

# Host-side entry points this repo owns. None can be invoked from inside a
# container (no docker socket, no docker client, and these live in the sandbox
# tool's tree, not the consumer repo's). Enumerable, so checkable.
mechanisms() {
  grep -oE 'with-egress|sync-agent-notice|profile\.sh|run-ephemeral|verify-sandbox|docker[[:space:]]+(compose|exec|run)' "$1" \
    | sort -u
}

printf "\n-- canonical notice --\n"

check "notice names no repo-relative path  <-- LOCK" \
  "$(relpaths "$NOTICE" | tr '\n' ' ' | sed 's/ $//')" ""

check "notice names no host-side mechanism  <-- LOCK" \
  "$(mechanisms "$NOTICE" | tr '\n' ' ' | sed 's/ $//')" ""

# --- the rules bite: a fixture carrying each defect must be caught ---
FIX=$(mktemp -d) || exit 1
trap 'rm -rf "$FIX"' EXIT

cat > "$FIX/relpath.md" <<'FIXTURE'
- If a package is missing, ask the human (or via `scripts/with-egress.sh`).
FIXTURE
check "a repo-relative path IS caught  <-- LOCK" \
  "$(relpaths "$FIX/relpath.md")" "scripts/with-egress.sh"

cat > "$FIX/mech.md" <<'FIXTURE'
- Ask the human to widen egress with with-egress, then run docker compose up.
FIXTURE
check "a host-side mechanism IS caught  <-- LOCK" \
  "$(mechanisms "$FIX/mech.md" | tr '\n' ' ' | sed 's/ $//')" "docker compose with-egress"

# --- the rules do NOT bite on the forms the notice legitimately uses ---
# Every line here is copied from the real notice. A rule that flags these is a
# rule that gets loosened until it flags nothing, so they are locked as
# negatives rather than left to chance.
cat > "$FIX/legit.md" <<'FIXTURE'
- Invoke it by full path: `/usr/lib/wsl/lib/nvidia-smi`. `/dev/dxg` is the GPU.
- Skills at `~/.claude/skills/<name>/SKILL.md`, plugins at `~/.claude/plugins/`.
- `/workspace`, `/tmp`, `/root/.local`, `/root/.npm-global`, `~/.local/bin`.
- `git push/pull/fetch/clone`, `cargo/go install`, `npm/pnpm run|test`.
- `git add/commit/diff/log/show/checkout/stash` are allowed.
- `.env`, `*.env.*`, `*.key`, `*.pem`, `**/credentials` are unreadable.
FIXTURE
check "absolute, agent-home, glob and command-list forms all pass" \
  "$(relpaths "$FIX/legit.md")" ""

printf "\n-- notice agrees with the deny list --\n"

# The notice promising a denial that permissions.deny does not carry is the
# dangerous direction: an agent reads "denied", does not attempt it, and the
# claim is never tested. Every fetch-and-run form the notice names must have a
# real deny entry behind it.
for cmd in "npx" "npm exec" "pnpm exec" "pnpm dlx" "yarn dlx" "bunx" "bun x" "pip download"; do
  in_notice=no; in_deny=no
  grep -qF "\`$cmd\`" "$NOTICE" && in_notice=yes
  grep -qF "\"Bash($cmd:*)\"" "$SETTINGS" && in_deny=yes
  if [ "$in_notice" = yes ] && [ "$in_deny" = yes ]; then
    ok "notice names '$cmd' and permissions.deny carries it"
  elif [ "$in_notice" = yes ]; then
    bad "notice names '$cmd' but permissions.deny has no Bash($cmd:*) entry"
  else
    bad "notice no longer names '$cmd' (deny entry exists; the prose drifted)"
  fi
done

printf "\n  %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
