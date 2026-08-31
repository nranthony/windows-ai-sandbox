# 0017 — `tar -cf <file>` fails in every container: `creat` is not in `seccomp.json`

**Status: IMPLEMENTED 2026-08-28** — allowed, documented, and locked by a
behavioural probe in `verify`. **The running containers are still on the old
profile**: seccomp is applied at container START, so this takes effect at each
profile's next `up`, and `verify` FAILS the new probe until then (see §9). That
failure is the change working, not a regression.

**Touches a security-sensitive surface:** `seccomp.json`. Per AGENTS.md any change
needs the security impact stated in the commit message, `verify` (tier 1) passing,
and `audit` (tier 2) for anything non-trivial.

**Found sideways**, while checking whether `uv python install` could extract an
interpreter under `cap_drop: ALL` (work/0016 follow-up, the
`UV_PYTHON_INSTALL_DIR` fix). It is unrelated to uv and much broader.

---

## 1. The symptom

Creating a tar archive as a **file** fails in every profile, on every filesystem:

```
$ tar -cf /root/.cache/x.tar src
tar: /root/.cache/x.tar: Cannot open: Operation not permitted
tar: Error is not recoverable: exiting now
```

Measured 2026-08-28 in `ai-sandbox-nranthony`, GNU tar 1.35, glibc 2.39,
kernel 6.18.33.2-microsoft-standard-WSL2.

## 2. What is and is not broken

The failure is narrower than "tar is broken", and the shape is what makes it
confusing to hit:

| Operation | Result |
|---|---|
| `tar -cf <file> …` | **FAILS**, EPERM |
| `tar -cf - … > <file>` | works |
| `tar -xf …` (extract) | works |
| `tar -cf - …` to a pipe | works |
| shell `> file`, `dd of=`, Python `open(…, "wb")` | works |
| `gzip -c … > file` | works |
| `git archive -o <file>` | works |

So it is not a mount property (`/tmp`, `/workspace` and `/root/.cache` all fail
alike — tmpfs and two ext4 bind mounts), not `O_CREAT` (it fails even when the
target file already exists), and not a permissions or capability problem in the
ordinary sense.

**Why this is easy to misdiagnose.** "Operation not permitted" on a write path,
inside a container that runs `cap_drop: ALL`, reads as a capabilities problem.
It is not. `CapEff` is `0000000000000000` and that is correct and unrelated —
the neighbouring `chown` failure IS capability-driven (the `[beads-install]`
block in `proxy/allowed_domains.txt` already documents that one), and having the
two failures sit next to each other in the same container invites folding them
into a single wrong explanation.

## 3. Diagnosis — `creat`, confirmed by bisection

`seccomp.json` is an allowlist (`defaultAction: SCMP_ACT_ERRNO`,
`defaultErrnoRet: 1` = EPERM). It allows 238 of the 373 syscalls in the
platform's `unistd_64.h`; **`creat` is one of the 135 it denies.**

GNU tar 1.35 creates its output archive with `creat()`, not `open()`/`openat()`.
That is the entire bug.

Confirmed in three steps, each a throwaway `docker run --rm --network none`
with no mounts, `--cap-drop ALL` and `no-new-privileges` held constant so that
only the seccomp profile varied:

| Profile | Result |
|---|---|
| repo `seccomp.json` | FAIL, EPERM |
| `seccomp=unconfined` | **works** — isolates the cause to seccomp |
| `seccomp.json` + `fchmodat2` | FAIL — hypothesis rejected |
| `seccomp.json` + **`creat`** | **works**, archive written correctly |

The `fchmodat2` line is kept deliberately: glibc 2.39 on a 6.6+ kernel routes
some `fchmodat()` calls through the newer syscall, so it is the plausible-looking
wrong answer, and it is also genuinely missing from the allowlist. Testing it
first and watching it fail is what forced the full denied-set bisection.

## 4. The proposed change, and why it is a smaller decision than it looks

Add `creat` to the same `SCMP_ACT_ALLOW` group that already carries
`open`/`openat`/`openat2` in `seccomp.json`.

**This grants no new capability.** `creat(path, mode)` is defined as exactly
`open(path, O_CREAT|O_WRONLY|O_TRUNC, mode)` — it is a legacy alias retained for
compatibility, and all three of `open`, `openat` and `openat2` are **already
allowed**. Anything reachable through `creat` is already reachable today through
a call the profile permits. Denying it buys no containment; it only breaks the
callers old enough to still use it. Docker's own default seccomp profile allows
`creat`.

The honest counter-argument, which should be stated in the commit either way:
this profile is deliberately tighter than Docker's default, and "the default
allows it" is not on its own a reason. The argument that carries the change is
the equivalence above, not the precedent.

## 5. Why it matters beyond tar

Anything that shells out to `tar -czf <file> …` is silently broken in every
profile — backup helpers, `just` recipes that bundle a directory, an agent
asked to "archive this folder". It fails at the point of use with a message
that points at permissions, and the working alternative (`tar -cf - … > file`)
is non-obvious enough that the likely response is to go hunting for a
capability or a mount flag that is not the problem.

Nothing in this repo's own tooling appears to hit it — `git archive -o` uses a
different path and works, and the vendor/skills machinery does not create
tarballs. So this is a latent trap for workspace code and for agents, not a
current breakage of the sandbox itself. That is an argument about urgency, not
about whether to fix it.

## 6. Steps

1. Add `creat` to the `open`/`openat`/`openat2` allow group in `seccomp.json`.
2. `scripts/profile.sh <profile> verify` (tier 1), then `audit` (tier 2) — this
   touches the syscall boundary, so it is not trivial by AGENTS.md's rule.
3. Re-run the `tar -cf <file>` case in a real profile, not only a throwaway.
4. Commit message states the security impact: a legacy alias for an already-
   permitted call, no new reachable behaviour, with the equivalence spelled out.
5. seccomp changes need no image rebuild, but **do** need a container recreate
   (`scripts/profile.sh <profile> up`) — the profile is applied at container
   start.

## 7. Open question worth a look while in here

The bisection produced the full 135-syscall denied set. `creat` is the one with
a proven live failure, but the same class of breakage — a legacy or newer alias
for something already allowed, denied by omission rather than by decision — may
exist elsewhere in it. `fchmodat2` is the obvious candidate: it is missing, and
on glibc 2.39 + kernel 6.6+ it is the modern route for `fchmodat()` with flags,
which IS allowed. Nothing has been measured to fail because of it yet.

`clone3` is also denied and was checked: Python threading and `subprocess` both
work, because glibc falls back to `clone`. Worth knowing, since an EPERM (rather
than ENOSYS) return from `clone3` is a documented way to break that fallback in
other runtimes.

Deciding the whole denied set is out of scope here; noting that it was never
audited as a set is not.

## 8. Non-goals

- Auditing all 135 denied syscalls (§7 — separate work if it is wanted).
- Adding `strace` to the image. The bisection did not need it and a debugger in
  a hardened image is its own decision.
- Anything about `chown`/`CAP_CHOWN`. That failure is real, is correct, and is
  already documented where it bites.

---

## 9. What shipped (2026-08-28)

**`seccomp.json`** — `creat` added to the `open`/`openat`/`openat2` line of the
same `SCMP_ACT_ALLOW` group, placed there rather than alphabetically so the
equivalence that justifies it is visible at the point of edit. The block's
`_comment` records why, per the editing rule in `docs/seccomp-notes.md`. Allowed
syscalls: 238 → 239.

**`scripts/verify-sandbox.sh`** — a behavioural probe beside the existing
`seccomp mode 2` check: create a real archive with `tar -cf <file>`, fail loudly
naming this work item if it EPERMs. Three deliberate choices:

- **Behavioural, not a grep of the JSON.** The host file says nothing about the
  profile a *running* container was started with, and this change is exactly the
  case where those two disagree until a recreate. A static check would have gone
  green immediately and proved nothing.
- **`tar -cf <file>`, never `tar -cf - > file`.** The pipe form is the
  workaround; it passes either way, so a probe using it would be decorative.
- **It sits with the seccomp check**, not with the tool-presence checks, because
  what it is really asserting is the syscall filter — tar is only the witness.

This is the first regression lock of any kind on `seccomp.json`, which has no
test suite (§7's "never audited as a set" is the wider version of the same gap).

**`docs/seccomp-notes.md`** — `creat` added to the must-stay table with the
symptom, and a new section on why the lock is behavioural.

### Measured, after the change

- `depaudit`-unrelated suites unaffected; `just test-offline` green (ten suites).
- `scripts/profile.sh nranthony verify` on the **still-running** container:
  `52 passed | 1 failed`, the one failure being the new probe —
  `tar -cf <file> EPERM — creat missing from seccomp.json? (work/0017)`.
  That is the pre-change profile being detected, which is the proof the probe
  is load-bearing rather than self-satisfying. It goes green on the next `up`.

### Remaining owner steps

1. `scripts/profile.sh <profile> up` for each of `nranthony`, `therapod`,
   `fluidmomenta` — no rebuild needed, seccomp is a runtime option.
2. Re-run `verify` after that: the probe should pass.
3. Tier-2 `audit` deliberately NOT run yet — run it once the containers are on
   the new profile, since an audit of the old one says nothing about this change.
