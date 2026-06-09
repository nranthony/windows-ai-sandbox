# Handoff → macolima: per-profile subnet allocation

**From:** `windows-ai-sandbox` (WSL2 Ubuntu, bash 5.2, rootless Docker)
**To:** `macolima` (macOS, bash 3.2.57, Colima)
**Date:** 2026-06-08
**Re:** Your audit of our subnet-allocator scoping doc, + a drop-in portable implementation and the bugs we hit building it.

---

## TL;DR

- Your audit was **correct for your platform**. The "fatal: associative arrays" call is real on bash 3.2 — it just wasn't fatal on *our* bash 5.2 (the code ran). We took the point anyway and rewrote the allocator in the **bash-3.2 portable subset** so it drops into your repo verbatim.
- The full allocator is in [§4](#4-drop-in-allocator-bash-32-safe) below — lift it as-is.
- We hit **two bugs your audit didn't mention** (a `set -e` + command-substitution interaction, and a missing `mkdir -p`). Both are platform-independent and **will bite you too** — details in [§5](#5-bugs-we-hit-that-will-affect-you-too).
- A few **macOS-specific things to verify on your side** in [§6](#6-macos-specifics-to-double-check-on-your-side).

---

## 1. The feature, briefly

Each profile's `sandbox-internal` network was hardcoded to `172.30.0.0/24` in `docker-compose.yml`. That makes profiles mutually exclusive: bringing up a second profile while one is running fails with:

```
Error response from daemon: invalid pool request: Pool overlaps with other one on this address space
```

Fix: parameterize the third octet on `${SANDBOX_OCTET:-0}` and allocate a stable, unique octet per profile. The same variable drives the **subnet**, the three `ipv4_address` pins (egress-proxy/postgres/mongo `.10/.20/.30`), and the three `extra_hosts` entries — one source of truth, so the pin list and the resolver list **cannot drift**.

> ⚠️ **Drift is a hard failure, not graceful**, because DNS is sinkholed (`dns: [127.0.0.1]`) and `extra_hosts` is the *only* name-resolution path. If the `ipv4_address` pins and `extra_hosts` ever disagree, the agent dials a dead IP: proxy mismatch → **all egress dies**; DB mismatch → connection refused. Deriving both from one variable is what makes that class of bug impossible.

---

## 2. What your audit got right (confirmed on our side)

| Your finding | Confirmed |
|---|---|
| `sandbox-internal` is the only shared-by-value resource; exactly the subnet + 3 `ipv4_address` + 3 `extra_hosts` need parameterizing | ✅ identical here |
| `run-ephemeral.sh` is subnet-agnostic (reaches proxy by name, no pinned IP) — no change needed | ✅ confirmed |
| `setup.sh`/`with-egress.sh` call `docker compose` directly and need the export | ✅ — we handled `setup.sh` by **delegating its `--recreate` to `profile.sh recreate`** instead of a direct `compose up`; `restart`/`ps` are network-neutral and the `:-0` default covers them |
| Associative arrays + `md5sum` are non-portable to bash 3.2 / macOS | ✅ **right for your platform** — see §3 |

## 3. What was platform-specific (don't over-correct)

These were true for *your* environment but not bugs in *ours* — flagging so the framing is clear, not to dispute:

- **bash 3.2 / no assoc arrays / `;;&` ban**: that's your `docs/sandbox-design-notes.md` mandate. We're on bash 5.2 with no such mandate; the original code ran fine here. We still rewrote to the portable subset for cross-port parity (cost ≈ 0).
- **`md5sum` vs macOS `md5`**: correct — macOS ships `md5` with different output. We switched to POSIX **`cksum`** (identical output Linux + macOS). Bonus: it's deterministic, so `wipe`→`up` reclaims the same octet.
- **Profile-name / line-number specifics**: those referenced your repo's disk state and an older compose layout — N/A across the boundary. Mentioning only so you don't chase them here.

---

## 4. Drop-in allocator (bash-3.2 safe)

Written deliberately in the portable subset: **no associative arrays**, **no `xargs -r`**, **`cksum` not `md5sum`**, **`if` blocks not `&&`-statements** (see §5 for why the last one matters). "Used octet" sets are carried as space-padded strings (`" 0 65 187 "`) tested with a `case` glob — the 3.2-safe equivalent of an assoc-array membership check.

Requires `PROFILE`, `PROFILES_ROOT`, `COMPOSE_PROJECT_NAME`, and `fail`/`warn` helpers in scope (same as ours).

```bash
# Deterministic first-choice octet (0-255) from the profile name. Stable across
# wipes; cksum is POSIX and identical-output on Linux + macOS (md5sum is not).
octet_start() { printf '%s' "$1" | cksum | awk '{print $1 % 256}'; }

# Collect octets already claimed by OTHER profiles' subnet-octet files into a
# space-padded string. Shared by both functions below.
sibling_octets() {
  local d name o out=" "
  for d in "$PROFILES_ROOT"/*/; do
    if [[ ! -d "$d" ]]; then continue; fi           # literal glob when no profiles
    name="$(basename "$d")"
    if [[ "$name" == "$PROFILE" ]]; then continue; fi
    if [[ ! -f "$d/subnet-octet" ]]; then continue; fi
    if ! read -r o < "$d/subnet-octet"; then continue; fi
    if [[ "$o" =~ ^[0-9]+$ ]]; then out="$out$o "; fi
  done
  printf '%s' "$out"
}

# First free octet at/after the name-hash start that is NOT in $1 (a space-padded
# "used" string). Echoes the octet, or empty if the /24 space is exhausted.
first_free_octet() {
  local used="$1" start i c
  start="$(octet_start "$PROFILE")"
  for (( i=0; i<256; i++ )); do
    c=$(( (start + i) % 256 ))
    case "$used" in *" $c "*) continue ;; esac
    printf '%s' "$c"; return
  done
}

# Cheap path (no docker calls): reuse persisted octet, or assign one from the
# name hash, skipping octets other profiles' files already claim. Exports SANDBOX_OCTET.
ensure_subnet_octet() {
  local f="$PROFILES_ROOT/$PROFILE/subnet-octet" want
  if [[ -f "$f" ]] && read -r want < "$f" \
     && [[ "$want" =~ ^[0-9]+$ ]] && (( want <= 255 )); then
    export SANDBOX_OCTET="$want"; return
  fi
  want="$(first_free_octet "$(sibling_octets)")"
  [[ -n "$want" ]] || fail "no free /24 in 172.30.0.0/16 (256-profile max)"
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$want" > "$f"
  export SANDBOX_OCTET="$want"
}

# Pool check (call right before a network-creating `compose up`): if our /24 is
# already held by ANOTHER docker network (non-profile project, or a stale net),
# bump to the next free octet and rewrite the file. Skips our own sandbox-internal
# so recreate doesn't flag itself. Only on up/recreate/rebuild.
ensure_octet_free() {
  local own="${COMPOSE_PROJECT_NAME}_sandbox-internal" net sub want taken
  taken="$(sibling_octets)"
  while read -r net sub; do
    if [[ "$net" == "$own" ]]; then continue; fi
    if [[ "$sub" =~ ^172\.30\.([0-9]+)\.0/ ]]; then taken="$taken${BASH_REMATCH[1]} "; fi
  done < <(docker network ls -q 2>/dev/null \
            | while read -r id; do
                docker network inspect "$id" \
                  --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null || true
              done \
            | awk '{for (i=2;i<=NF;i++) print $1, $i}')
  case "$taken" in
    *" ${SANDBOX_OCTET} "*) ;;   # our /24 is occupied — fall through, reallocate
    *)                      return ;;   # free — keep current assignment
  esac
  want="$(first_free_octet "$taken")"
  if [[ -z "$want" ]]; then fail "no free /24 in 172.30.0.0/16 (pool check)"; fi
  mkdir -p "$PROFILES_ROOT/$PROFILE"
  printf '%s\n' "$want" > "$PROFILES_ROOT/$PROFILE/subnet-octet"
  warn "172.30.${SANDBOX_OCTET}.0/24 already in use; reassigned '$PROFILE' to 172.30.${want}.0/24"
  export SANDBOX_OCTET="$want"
}
```

**Wiring** (matches ours):
- Call `ensure_subnet_octet` once, right after you `export PROFILE`/`COMPOSE_PROJECT_NAME`, for *every* profile command — so `down`/`status`/`logs` also see the correct subnet. It's a cheap file read after first assignment.
- Call `ensure_octet_free` only in the network-creating arms (`up`/`recreate`/`rebuild`), just before `docker compose up`.
- compose: `subnet: 172.30.${SANDBOX_OCTET:-0}.0/24` and the six pins/hosts as `172.30.${SANDBOX_OCTET:-0}.{10,20,30}`. The `:-0` default keeps the legacy subnet for your build sentinel (`PROFILE=_build`/`_test`, which never creates a network) and the network-neutral `restart`/`ps` paths.

---

## 5. Bugs we hit that will affect you too

Neither was in the audit; both are platform-independent.

### 5a. `set -e` + `[[ … ]] && continue` inside command substitution

When we factored the loops into helpers called via command substitution (`$(sibling_octets)`), a standalone `[[ test ]] && continue` whose test is **false** returns nonzero and **trips `set -e`**, aborting the subshell *before* the function's `printf`. Result: the function silently returns the empty string — no error, just wrong data. (The originally-inlined version dodged it; extracting into `$( )` exposed it.)

**Fix:** use explicit `if [[ … ]]; then continue; fi` — `if` conditions are exempt from `set -e` in every context. We apply this to every guard in the helpers. If your scripts run `set -euo pipefail` (ours is line 56 of `profile.sh`), you'll hit this identically.

`X || continue` is **safe** (the right side runs and returns 0); only `X && continue`/`X && assignment` as standalone statements are the hazard.

### 5b. `ensure_octet_free` wrote the octet file without `mkdir -p`

The reallocation path wrote `$PROFILES_ROOT/$PROFILE/subnet-octet` assuming the dir exists. In the normal flow it does (`ensure_subnet_octet` runs first and `mkdir -p`s it), but defensively it should create it too. Added `mkdir -p "$PROFILES_ROOT/$PROFILE"` before the write. (Already included in §4.)

### 5c. Testing gotcha (cost us time — flagging so it doesn't cost you)

`octet_start()` is a one-liner ending in `; }`, **not** a bare `}` on its own line. Extracting functions for unit testing with `sed -n '/^foo()/,/^}$/p'` therefore **over-runs** into the next function and silently duplicates definitions, producing a corrupted self-redefining function that returns empty. If you unit-test by extraction, bound the range by the next section banner (we used `awk '/^octet_start\(\)/{f=1} /^# parse_flags —/{f=0} f'`), or just test end-to-end against the real script.

---

## 6. macOS specifics to double-check on your side

The §4 code is portable, but a few things depend on your environment — please verify:

1. **`cksum`** — POSIX, present on macOS, identical output. ✅ should be safe. (Octet *values* will differ from ours only because profile names differ; determinism is what matters, and it holds.)
2. **Process substitution `< <(…)`** — works in bash 3.2 *where `/dev/fd` exists*, which macOS has. ✅ But if you ever run any of this under `/bin/sh`, process substitution is gone — keep it in `#!/usr/bin/env bash` scripts.
3. **`xargs -r`** — deliberately avoided (it's GNU-only; BSD `xargs` runs the command once on empty input). We replaced it with `docker network ls -q | while read -r id; do docker network inspect …; done`. Don't reintroduce `xargs -r`.
4. **`docker network inspect --format`** — Go-template output is engine-side, identical under Colima. The `awk '{for(i=2;i<=NF;i++)…}'` split handles networks with 0 subnets (host/none) and multiple subnets. ✅
5. **`md5sum` is *not* present by default on macOS** — this is exactly why we moved to `cksum`. If any *other* part of your scripts still calls `md5sum`, it'll break on a clean Mac.
6. **Colima IP pool** — our pool check scans `172.30.x.0/24`. Confirm Colima's default bridge/VM networks don't already sit in `172.30.0.0/16`; if they do, the pool check will route around them (good), but worth knowing your baseline.

---

## 7. How we verified (suggested for your side too)

- **Unit**: source the four functions under `set -euo pipefail`; assert `sibling_octets`, `first_free_octet`, and `ensure_octet_free` against live `docker network` state (force `SANDBOX_OCTET` to an occupied octet → must bump; to a free one → must keep).
- **End-to-end**: bring up a second (and third) profile alongside a running one; confirm distinct `172.30.x.0/24` per `docker network inspect`, that `extra_hosts` resolves the proxy to the matching `.10`, that external DNS still fails (sinkhole intact), and that egress to an allowlisted host succeeds through the proxy.

On our side: 3 profiles coexisted cleanly (`.0`, `.187`, `.85`), proxy reachable at the per-profile `.10`, external DNS blocked, allowlisted egress OK.

---

## 8. One migration note (applies symmetrically)

Existing profiles have **no** `subnet-octet` file, so on their next `recreate` they reallocate off `.0` (one-time network rebuild). To pin an existing profile in place and avoid the rebuild, pre-seed it: `echo 0 > <profiles>/<name>/subnet-octet`. We chose to let ours migrate; your call.

---

*Per the sibling-repo principle: this is information and a portable reference, not a directive to blind-copy. Your privilege model (rootful-ish vs our rootless userns=host) and VS Code integration differ — the allocator is substrate-agnostic, but re-verify the wiring against your `setup.sh`/`with-egress.sh` call sites.*
