# 0021 — Controls to pull BACK from macolima into this repo

**Status: PARKED — do not execute yet.** Everything below was measured on
2026-08-31 against `macolima@8d7eceb` (2026-08-23), which is macolima's HEAD and
is **stale by design**: that repo has had no implementation commit since
2026-07-19 and is waiting on the Mac. Its last commit is a *plan* about pulling
from here, not a change.

> ### ⚠ REMINDER — surface this whenever 0021's status is asked for
>
> **The owner will re-validate this item AFTER macolima has been updated.**
> The findings here are a snapshot against a repo that is about to move. Once
> [0022](../0022-port-forward-to-macolima/spec.md) lands and its handoff is
> executed on the Mac, macolima's probes and `verify-sandbox.sh` will have
> changed underneath every measurement in §3 — and several §3 rows may resolve
> themselves, because 0022 pushes this repo's stronger versions of the same
> checks in the other direction. **Re-run §2 before acting on §3.** Do not
> implement anything here off the 2026-08-31 numbers alone.
>
> **Also open: ❗D2 (§5)** — flagged by the owner on 2026-08-31 as important and
> deliberately undecided. Same revisit trigger. It is the only row here that
> would add a control neither repo has, so it has no sister-repo answer to check
> against.

**Direction:** macolima → windows-ai-sandbox. This is the *reverse* of the usual
flow and of [0022](../0022-port-forward-to-macolima/spec.md). It exists because
`docs/sibling-repo-relationship.md` says the point of keeping both repos is that
each is an independent check on the other — and nothing in this repo has ever
acted on that in this direction. macolima's own `work/0001` §A9 queued it as
"send M's verify checks back to W (open a W work item, don't do it here)". This
is that item.

**Security-sensitive surfaces if implemented:** `scripts/verify-sandbox.sh`,
`scripts/audit/probes/`. Per AGENTS.md each needs the security impact in the
commit message, tier-1 `verify` passing, and tier-2 `audit` for anything
non-trivial.

---

## 1. Why this is not just "diff the two repos"

The comparison has a trap that already caught the 2026-08-23 plan. macolima's
`work/0001` §A9 named five candidates to send back here:

> non-root UID, external-DNS exfil probe, live CONNECT-on-80 probe, SUID/SGID
> drift, stray UID-0 processes

**Four of the five are wrong as stated**, measured 2026-08-31 (§3). They were
written from line counts and file sizes — macolima's `fs.py` is 284 lines to our
258, `seccomp_runtime.py` 205 to our 198 — and a bigger file was read as a
richer check set. It is not: this repo has since renamed several checks
(`H1_connect_80_blocked` → `connect_80_blocked`) and *strengthened* others in
place, so a name-level diff reports absences that are really renames and misses
divergences that are really substance.

The rule this item should leave behind: **compare check semantics, never file
size and never check names.** The extraction that produced §3 is in §2 so the
next person does not redo it by eye.

## 2. How the comparison was run (repeat this before acting)

Both repos on the same host, read-only, no docker:

```bash
M=~/repo/sandbox/macolima
H=~/repo/sandbox/windows-ai-sandbox

# tier-2 probe check names, both directions
python3 - "$M" "$H" <<'PY'
import re, sys, pathlib
pat = re.compile(r'_check\(\s*"([^"]+)"\s*,\s*f?"([^"{]*)', re.S)
sets = []
for repo in sys.argv[1:]:
    seen = set()
    for f in sorted((pathlib.Path(repo) / "scripts/audit/probes").glob("*.py")):
        for sec, name in pat.findall(f.read_text()):
            seen.add(f"{sec}/{name}")
    sets.append(seen)
print("M-only:", *sorted(sets[0] - sets[1]), sep="\n  ")
print("H-only:", *sorted(sets[1] - sets[0]), sep="\n  ")
PY

# tier-1 tripwire content — these are shell, so compare by subject not by name
diff <(grep -oE '(pass|fail|warn) "[^"]+"' "$M/scripts/verify-sandbox.sh" | sort -u) \
     <(grep -oE '(pass|fail|warn) "[^"]+"' "$H/scripts/verify-sandbox.sh" | sort -u)

diff "$M/seccomp.json" "$H/seccomp.json"        # expect: creat only, until 0022 lands
diff "$M/proxy/squid.conf" "$H/proxy/squid.conf" # expect: wording + mount path only
```

The `_check(` regex catches the literal-name call sites only; names built from
an f-string (`f"named_volume_{...}"`) come out truncated at the brace, which is
why §3 treats those rows as "needs eyes", not as a clean absence.

## 3. Findings — what macolima actually has that we do not

Four rows. Two are real, one is divergent-by-design, one is a deliberate choice
worth re-examining. Everything else in §A9's list is already here.

| # | macolima control | State here | Verdict |
|---|---|---|---|
| F1 | **SUID/SGID inventory as a tier-1 tripwire** — `verify-sandbox.sh:143-161`, `find / -xdev -perm /6000` against a 12-name stock-Ubuntu set, FAIL on any drift | Tier-**2** only. `scripts/audit/probes/identity.py:15` carries the identical `EXPECTED_SUID` set, but `verify-sandbox.sh` has no SUID check at all | **PORT** — see §4 |
| F2 | **`settings/hook_file_immutable`** — asserts `exists and root_owned and executable and not agent_writable` | `settings/hook_present_on_disk` asserts `exists and executable` only | **ASSESS** — see §5. Not a straight port; the property macolima checks may not be the property that protects the hook here |
| F3 | **`no stray UID-0 processes`** — `verify-sandbox.sh:223-229`, `ps -eo pid,user`, any root process other than PID 1 is an attach orphan | Absent | **REJECT** — the container runs as UID 0 by design here (rootless userns, container 0 ↔ host 1000). Every process is root; the check would report the container's normal state as drift. The equivalent question here — "did VS Code leave an orphan `docker exec` shell?" — is a different check and is not written in either repo |
| F4 | **`proxy/no_vendor_wildcards` + `proxy/no_other_wildcards`** — a leading-dot entry in the allowlist is **DRIFT** | `proxy/wildcard_entries` reports the same entries as **INFO**, never DRIFT | **KEEP AS IS, but record why** — see §6 |

### Confirmed already present here — §A9's list was stale

Recorded so nobody re-opens them:

- *non-root UID* — inapplicable by substrate; `identity/uid` plus
  `identity/userns_root_to_host_1000` (this repo only) cover the invariant that
  actually holds here.
- *external-DNS exfil probe* — present, `network.py`, `external_dns_blocked`.
- *live CONNECT-on-80 probe* — present, `network.py`, `connect_80_blocked`
  (macolima calls the same check `H1_connect_80_blocked`; the audit-finding
  prefix was dropped here, which is what made it look absent).
- *`bwrap` / `socat` / `ssh` absence* — present, `verify-sandbox.sh:297-299`.
- *credential.helper resolved across all git config layers* — present,
  `verify-sandbox.sh:365-385` (`git config --show-origin --get-all`).
- *planning-mode blocks stay commented* — present and **stronger** here:
  `proxy/gated_blocks_default_off` carries an `ACCEPTED_OPEN_TAGS` set that
  macolima's `planning_mode_commented` has no equivalent of. This one goes the
  other way; it is a 0022 row.
- *`squid.conf` ACL order* — both repos check it and both close the
  CONNECT-on-port-80 hole. macolima spells it `deny CONNECT !SSL_ports`; we
  spell it `allow CONNECT SSL_ports allowed_domains` + `deny CONNECT`.
  Semantically equivalent, verified line by line. **Neither is a finding.** An
  earlier read of this diff suggested we were missing macolima's hard-deny; we
  are not.

## 4. F1 — the SUID tripwire, and why tier-2 is not enough

The two tiers answer different questions and only one of them runs routinely.
`verify` is the tripwire that every `up` and every agent session is expected to
pass; `audit` is the deeper pass run deliberately. A SUID binary arriving in the
rootfs — a `.deb` or a wheel that ships one — is exactly the drift a tripwire is
for, and today it is only visible if someone chooses to run tier 2.

The kernel boundary does neutralise it at runtime (`no_new_privileges` +
`cap_drop: ALL`, both already asserted at tier 1), so this is not an open hole.
It is a **detection latency** gap: the finding exists and nothing routine reports
it.

**Not a copy-paste.** Two things must be re-derived, not carried over:

1. **The expected set.** macolima's 12 names come from a digest-pinned
   `ubuntu:24.04`. This repo builds on `nvidia/cuda:12.6.3-base-ubuntu24.04`.
   `identity.py` already asserts the same 12 names against the CUDA base and
   this repo's audits pass, which is good evidence the set is unchanged — but
   the tier-1 check must read the constant from one place, not restate it. A
   second hand-maintained copy of a security constant in a second file is the
   `pnpm dlx` drift shape that `agent-policy.test.sh` exists to prevent.
2. **`xargs -r`.** macolima's implementation uses it. It is a GNU extension.
   Harmless here (this repo is bash 5 / GNU coreutils) but it must not be copied
   back to macolima later as if it were portable — `work/0001` §1 puts that repo
   in the bash-3.2 subset.

**Design question (D1):** does the tier-1 check re-run `find / -xdev -perm /6000`
(a full-rootfs walk on every `verify`, on a CUDA image), or does it assert
against a manifest captured at build time? The walk is honest but slow; the
manifest is fast but can be stale in exactly the case it exists to catch. Owner
decision — measure the walk's cost on a real profile first.

## 5. F2 — hook immutability, honestly

macolima checks that the hook file is root-owned and not writable by the `agent`
user. That check is meaningful there because the agent is UID 1000 and the file
is UID 0: the kernel enforces it.

**Here it is not meaningful in that form.** The container runs as root, so the
agent can `chmod` and rewrite `/usr/local/lib/sandbox-hooks/` at will. macolima's
`work/0001` §1 states this plainly — "M's kernel write-protect on the hook is
real; W's is not". Porting the check as written would produce a probe that
either always passes (root owns it, root is us) or always fails, and in neither
case does it measure a defence.

The defence that actually holds here is different and is already documented in
AGENTS.md: **the hook engine is baked into the image**, so an in-container edit
is a writable-layer change that does not survive recreate, and
`converge_agent_policy` rewrites the policy half on every `up`. The honest
question this row should answer is therefore:

> ### ❗ IMPORTANT — D2 is OPEN and deliberately unanswered
>
> **D2 — is there a check that would catch an agent editing the baked hook engine
> inside a long-lived container, before the next recreate silently repairs it?**
>
> **Owner's call, 2026-08-31: flagged, not decided. Revisit — do not let a
> passing guess stand in for the answer.**
>
> A content hash of `/usr/local/lib/sandbox-hooks/*` against the image's copy is
> the obvious shape, but "obvious shape" is not a yes. What makes this worth
> stopping on rather than guessing:
>
> - It is the **only row in this item that would add a control neither repo
>   has.** Every other row is a port, a rejection, or a doc edit. There is no
>   sister-repo implementation to check the answer against — which is exactly
>   the condition under which this repo's cross-check discipline stops helping.
> - The window it covers is real but bounded, and nobody has measured it: an
>   edit survives only until the next recreate. Whether that window is hours or
>   weeks depends on profile lifetime, and **that number should be measured
>   before the check is designed** — a tripwire for a window that closes on
>   every `up` is a different control from one for a container running for weeks.
> - The failure posture is not obvious either. A hash mismatch after a
>   legitimate `build --refresh-ai` is the false-positive case, and a check that
>   reddens on an ordinary rebuild gets muted — the `vendor-tools.sh` prefix
>   over-match lesson, in a new place.
>
> **Revisit trigger:** answer this *after* [0022](../0022-port-forward-to-macolima/spec.md)'s
> handoff comes back, alongside the §3 re-measurement. Not before — 0022 touches
> the hook engine on the macolima side, and the answer may look different once
> both repos carry the same three-tier engine.
>
> **If D2 comes back yes, it gets its own work item.** Do not widen 0021 to
> hold it: 0021 is a port-assessment item, and a new detector is a design item
> with its own decision gates and its own test-suite obligation.

## 6. F4 — wildcards are INFO here on purpose

macolima fails on any leading-dot allowlist entry. This repo's allowlist has 32
tagged blocks to macolima's 15 and carries CDN parents that cannot be enumerated
as leaves — `.fal.media` is the worked example (`70e9213`), where the whole point
of the change was collapsing an unenumerable delivery host set to one wildcard.

Making that DRIFT would mean a permanently-red probe, which per this repo's own
standard (`vendor-tools.sh`: "a check that cries wolf on its first run is a check
that gets ignored") is worse than no check.

**No action — but record the divergence in `docs/sibling-repo-relationship.md`**
under "Divergent (copying these *causes* flaws)". It is currently absent there,
which is why it reads as a gap every time the two repos are compared. That doc
edit is the whole deliverable for F4 and it is worth doing on its own.

## 7. Scope boundary

Not in this item:

- Anything flowing the other way — that is [0022](../0022-port-forward-to-macolima/spec.md).
- macolima's `fs/named_volume_*` and `fs/tmpfs_owner_*` probes. Both are virtiofs
  UID-remap checks for Colima's named-volume workaround; this repo fights WSL2
  inode/ownership instead and has `fs/tmp_tmpfs_noexec` where macolima has
  neither. Different substrate, different check, no port.
- Rewriting either repo's probe framework to share code. They are deliberately
  independent implementations; that independence is what makes the cross-check
  worth running.

## 8. Definition of done

1. §2 re-run against macolima's **post-0022** state, and §3's table corrected
   against it — see the reminder at the top.
2. F1 implemented behind D1, with the expected-SUID set read from one place.
3. **D2 (§5) revisited and answered** — it is flagged OPEN and deliberately
   undecided as of 2026-08-31, with the revisit trigger tied to 0022's handoff
   return. This item does not close on an assumed answer. If yes, a new work
   item is opened rather than widening this one.
4. F4's divergence written into `docs/sibling-repo-relationship.md`.
5. `scripts/profile.sh <p> verify` (tier 1) and `audit` (tier 2) both green on a
   live profile; no new DRIFT against the pre-change baseline.
6. `just test-offline` green.
