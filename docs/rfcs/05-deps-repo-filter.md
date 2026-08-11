# RFC: `--repo` filter for `profile.sh deps`

- Status: Draft — **not implemented.** Written 2026-08-06 at the operator's request,
  parked for a later session.
- Author: agent, from a request by nranthony

**Question this answers:** a profile's workspace holds many repos and `deps` reports on
all of them. When you are working in exactly one, can you scan just that one?

**Build status:** Plan. Nothing implemented. Line numbers below are against
`scripts/profile.sh` as of `32fd406`.

---

## Summary

Add `--repo <name>` to `scripts/profile.sh <profile> deps`, narrowing the posture scan
(and the `--osv` cross-check) to a single repo in the profile's workspace. No `justfile`
change is needed — `deps profile *args` already forwards flags — so
`just deps nranthony --repo myclickup` works as soon as `profile.sh` understands it.

The code is small. The care goes into making the narrowing *visible*, because a filtered
report that looks like a full one is the failure mode this repo already has scar tissue
for.

## Motivation

`deps` iterates the workspace root plus every immediate child holding a manifest
(`scripts/profile.sh:1164-1177`). That breadth is deliberate — the comment there records
that without it "the common case reports 'no manifests' and reads as clean". But the
common *use* is narrower: you have just installed into one repo and want that repo's
posture. Today that means reading past N-1 irrelevant reports to find it.

## Proposal

### Behaviour

```
scripts/profile.sh <p> deps --repo <name> [--osv] [--json] [--strict|--quiet]
```

- `--repo <name>` and `--repo=<name>` both accepted.
- `<name>` is an immediate child of the workspace. `.` (or the profile name) selects the
  workspace root itself, which discovery already treats as a scannable root.
- A name that is not in the discovered set is a **hard error listing what is**, exit 2.
  It never scans nothing and exits 0.
- The `md` header states the filter is active and how much it hid.
- The cross-repo roll-up is suppressed when filtered.
- `--history` is profile-scoped, not repo-scoped; combining the two is an error with a
  message that says why, not "unknown flag".

### Patch 1 — parser (replaces `scripts/profile.sh:1151-1162`)

The current loop is `for a in "$@"`, which cannot consume a following token, so a
value-taking flag needs a `while`/`shift` loop:

```bash
    dep_osv=0; dep_fmt="md"; dep_failon="warn"; dep_repo=""
    dep_usage="Usage: scripts/profile.sh $PROFILE deps [--repo <name>] [--osv] [--json] [--strict|--quiet]
             scripts/profile.sh $PROFILE deps --history [N]"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --osv)     dep_osv=1 ;;
        --json)    dep_fmt="json" ;;
        --strict)  dep_failon="fail" ;;
        --quiet)   dep_failon="never" ;;
        --repo)    [[ $# -ge 2 && -n "$2" ]] || fail "--repo requires a repo name
      $dep_usage"
                   dep_repo="$2"; shift ;;
        --repo=*)  dep_repo="${1#--repo=}"
                   [[ -n "$dep_repo" ]] || fail "--repo requires a repo name
      $dep_usage" ;;
        --history) fail "--history reports install windows for the whole profile and takes no
      other flags — it is not repo-scoped. Run it on its own.
      $dep_usage" ;;
        *)         fail "Unknown flag for deps: $1
      $dep_usage" ;;
      esac
      shift
    done
```

Both spellings reject an empty operand in the same place, so `--repo=` cannot slip
through as "no filter requested" — which would silently widen the scan back to the whole
workspace under a flag that says otherwise.

### Patch 2 — filter after discovery, not instead of it

Leave `scripts/profile.sh:1164-1178` **unchanged** and filter the result. Discovery is
pure `stat` calls, so running it even when filtering is free, and it buys two things: an
accurate "1 of N" for the header, and an error listing that is exactly the scannable set
rather than every directory.

Insert immediately after the existing `[[ -n "${dep_roots// /}" ]] || …` guard at
`scripts/profile.sh:1178`:

```bash
    # --repo narrows the scan to ONE repo. A filtered run is a deliberate
    # under-report, so it must never fail open: an unknown name is an error that
    # names the alternatives, not an empty run that exits 0 looking clean.
    dep_scope=""
    if [[ -n "$dep_repo" ]]; then
      read -ra dep_all <<< "$dep_roots"
      dep_repo="${dep_repo%/}"
      case "$dep_repo" in
        .|"$PROFILE") dep_target="$ws" ;;
        */*)          fail "--repo takes a repo name, not a path: $dep_repo" ;;
        *)            dep_target="$ws/$dep_repo" ;;
      esac
      dep_hit=""
      for r in "${dep_all[@]}"; do [[ "$r" == "$dep_target" ]] && { dep_hit="$r"; break; }; done
      if [[ -z "$dep_hit" ]]; then
        {
          printf 'No scannable repo named "%s" in %s\n\n' "$dep_repo" "$ws"
          printf 'Repos with a manifest:\n'
          for r in "${dep_all[@]}"; do printf '  %s\n' "$(basename "$r")"; done
        } >&2
        exit 2
      fi
      dep_scope="  [--repo filter — 1 of ${#dep_all[@]} repos with manifests]"
      dep_roots="$dep_hit"
    fi
```

`read -ra` and `${#arr[@]}` are bash-3.2-safe, which matters because `profile.sh` is
cross-ported to the `macolima` sibling. Avoid `mapfile`, `${var,,}` and associative
arrays here for the same reason.

### Patch 3 — state the scope in the header (`scripts/profile.sh:1184`)

```bash
      [[ "$dep_fmt" == "md" ]] && info "depaudit posture: $rel$dep_scope"
```

`dep_scope` is empty on an unfiltered run, so the default output is byte-identical to
today. Same one-line change at the `--osv` header a few lines below.

### Patch 4 — suppress the roll-up when filtered (`scripts/profile.sh:1204`)

```bash
    if [[ "$dep_fmt" == "md" && -n "$dep_summary" && -z "$dep_repo" ]]; then
```

Its stated purpose is that "a nine-repo workspace produces nine reports"; with one root
it prints a banner, one row, and a footer restating what the single report just said.

### Patch 5 — usage header (`scripts/profile.sh:52-60`)

Add `--repo <name>` to the `deps` flag list, with one clause on what it does *not* do:
it narrows the report, so a FAIL in a sibling repo will not appear.

### Docs to update

| File | What |
|---|---|
| `scripts/profile.sh:52` | usage header (patch 5) |
| `scripts/profile.sh` usage string | folded into patch 1 via `$dep_usage` |
| `AGENTS.md:165` | quick reference line gains `[--repo <name>]` |
| `docs/dependency-guardrails-handoff.md:205` | same command line, second home |
| `docs/index.md` | this RFC's resolution line |

No ADR. Per ADR-0001 this is local implementation detail — it does not touch the security
boundary, persistent data, a public contract, or cross-repo convention.

## Ramifications

**Nothing programmatic consumes `deps`.** Verified: no reference anywhere in
`dashboard/src`, and `scripts/depaudit.test.sh` exercises `depaudit.py` directly, never
the `profile.sh` subcommand. No test breaks; no downstream parser sees the output.

**Nothing tests this path either.** Of the four offline suites, only
`with-egress.test.sh` reaches into `profile.sh`, and only for `list_denied_domains`. The
`deps` flag parser is uncovered, so a regression surfaces only when a human runs it. For
a flag this size, the manual matrix below plus a `verify` run is proportionate; if the
parser grows a third value-taking flag, it has earned a suite.

**`scripts/profile.sh` is on the security-sensitive list in AGENTS.md.** So this needs a
commit message stating security impact, a passing `scripts/profile.sh <p> verify`, and
the doc updates above. Draft statement:

> Security impact: none to the boundary. `deps` runs host-side and read-only — it parses
> manifests, spawns no container, opens no egress, and touches no credential or allowlist
> path. `--repo` only narrows which manifests are read. The narrowing is stated in the
> report header and fails closed on an unknown name.

**The narrowing is the actual risk, and it is the one worth arguing about later.**
AGENTS.md's warning about `with-egress` is that a bug there "silently *under-reports* —
which reads exactly like a clean run." A `--repo` filter is a deliberate under-report. If
it becomes the habitual invocation, a FAIL in a sibling repo goes unseen indefinitely.
Patches 2 and 3 are the whole mitigation: fail closed on a bad name, and make the output
state its own scope. Neither is optional garnish — drop them and this becomes a footgun
that reads as a convenience.

**Pre-existing, not caused here:** `for r in $dep_roots` (`scripts/profile.sh:1182`)
iterates an unquoted space-separated string, so a workspace repo whose directory name
contains a space already breaks discovery today. `--repo` sidesteps it for the filtered
case and does not make it worse. Fixing it means moving `dep_roots` to a real array
throughout — a separate, larger change.

## Manual test matrix

Run in a profile whose workspace has ≥2 repos with manifests:

| Invocation | Expected |
|---|---|
| `deps` | unchanged from today, byte-for-byte |
| `deps --repo myclickup` | one report, header says `1 of N`, no roll-up |
| `deps --repo=myclickup` | identical to the above |
| `deps --repo nope` | exit 2, lists repos with manifests, scans nothing |
| `deps --repo` | exit 1, "requires a repo name" + usage |
| `deps --repo myclickup --osv` | posture + OSV, both scoped, both headers annotated |
| `deps --repo myclickup --json` | one JSON doc; no `info` lines on stdout |
| `deps --repo myclickup --strict` | exit 1 on FAIL, as unfiltered |
| `deps --history` | unchanged — short-circuits before the parser |
| `deps --repo x --history` | exit 1 naming the conflict, not "unknown flag" |
| `deps --repo .` | workspace root only |

## Open questions

1. **Should `--repo` accept more than one name?** `--repo a --repo b` currently
   last-wins. Repeatable-and-accumulating is a two-line change but complicates the
   "1 of N" header. Deferred until someone wants it.
2. **Should `--history` gain a repo filter separately?** The audit log records the full
   `cmd` string, so filtering windows by workspace path is feasible but is a different
   question — "what came in for this repo" rather than "how is this repo configured".
   Out of scope here.
3. **Is `.` the right spelling for the workspace root?** It reads as "current directory"
   but means "the workspace root", which is not where you are standing. `--repo _root`
   or accepting the profile name alone may be less confusing.

## Alternatives

- **`--repo=<name>` only, keeping the `for` loop.** Three lines instead of ~25. Rejected:
  inconsistent with `--history N`, which takes a bare value, and the `while` loop is
  needed anyway the moment a second value-taking flag appears.
- **Run `depaudit.py` directly against the one repo.**
  `python3 scripts/depaudit.py posture ~/repo/<p>/<repo>` already works today and needs no
  change at all. Rejected as the answer, though it remains the escape hatch: golden rule 1
  says discovery of what a profile can do lives in `profile.sh`, not in a script the user
  has to know about — and this route silently skips the `--fail-on` wiring and the OSV
  step that `deps` composes for you.
- **Filter in `depaudit.py` instead.** Wrong layer. `depaudit` is root-scoped by design
  and portable to repos outside any sandbox (RFC-04); workspace layout is `profile.sh`'s
  concern.
