# 0005 — the cross-repo skill pipeline: what was wrong, and what now watches it

**Status:** Work landed. Open only on the myclickup reply (§5). Raised and executed
2026-08-13; agentic-conventions answered the same day (§6) and step 8 is closed.

**Exit rule:** delete this folder, or move to [`docs/_archive/`](../../docs/_archive/),
once §5 is empty.

**Not security-sensitive**, with one exception: `verify-sandbox.sh` gained a check.
It removes nothing and relaxes nothing — see the commit's SECURITY IMPACT line.

---

## Origin

`just sync-skills --dry-run` failed outright:

```
[FAIL]  not an agentic-conventions checkout (no templates/.claude/skills)
```

The presenting symptom was a broken sync. The real question was why phantom skill
copies had reached every profile and stayed there across three upstream releases.

## The chain, and where it actually broke

```
hop 0  .claude/skills/ + reference/ + templates/  ->  plugins/myconv/            just sync-plugin
hop 1  plugins/myconv/                            ->  sandbox_templates/skills/  just sync-skills
hop 2  sandbox_templates/skills/                  ->  profiles/*/claude-home/    converge_skills
hop 3  profile dir                                ->  container ~/.claude/skills bind mount
```

**Every copying hop was already correct.** Two outside assessments suspected the
delete semantics — one checked hop 1, the other doubted hop 2. Both mirror:

- hop 1 (`sync-skills-from-conventions.sh:230,242`) — `diff -rq`, then `rm -rf` + `cp`
- hop 2 (`profile.sh:438-443`) — `diff -rq`, then `rm -rf` + `mv`
- hop 0 (`agentic-conventions/justfile`) — copies without deleting, but
  `check-plugin-sync` runs `diff -r` both ways and exits 1 on a leftover:
  detected, needs a human delete

`diff -rq` was tested rather than assumed: it reports `Only in …` for a
deletion-only change, including inside hidden directories, and exits 1. So a
prune-only release triggers the replace branch at both hops.

**The single defect was the hop-1 guard**, which asserted a content path
(`templates/.claude/skills`) that upstream had legitimately deleted. A correct
upstream prune failed the whole sync.

**So the phantoms were a cadence problem, not a mechanism problem.** Nothing was
leaking. The pipeline simply had not been run, and nothing anywhere reported that.

## What that exposed — the finding worth keeping

Copy count was never the issue. There were three git-tracked copies and three
derived caches; the caches self-heal on every `up` and had never drifted.

What hurt was the **one boundary between repos** where a stale copy sat unwatched.
And the detectors there were worse than absent — they failed in *opposite*
directions when unconfigured, so neither could be automated:

| Boundary | Detector | Lived | Unconfigured |
|---|---|---|---|
| agentic-conventions -> here | `check-vendored` | **upstream** | exit 0 — **false pass** |
| myclickup -> here | `vendor-check` | here | died — **false alarm** |

Worse, `.sandbox-repo.local` — which is what makes `check-vendored` do anything —
was created 2026-08-12 13:18, **two days after** the pin it exists to watch
(`3f60422`, 2026-08-10). For that whole window it printed `SKIPPED`, exited 0, and
`just check` reported "all checks passed" over it.

**Rule adopted: the detector belongs on the side that owns the stale copy, and a
skip is not a pass.**

## What landed

| Change | Where |
|---|---|
| Guard keys on the plugin marker (`*/.claude-plugin/plugin.json`), not a content path | `sync-skills-from-conventions.sh` |
| myconv re-vendored 0.1.0 -> 0.3.0; five skills; phantoms gone; pin -> `e6f395d` | `sandbox_templates/skills/` |
| All three profiles converged, then recreated onto a fresh image (Claude Code 2.1.231) | live |
| `*.bak*` check — `converge_skills` prunes only `*.bak.*`, so the unstamped form survives it | `verify-sandbox.sh` |
| Section 6: a file deleted inside a skill must vanish, at depth and behind a dot-dir. Mutation-tested | `profile-skills.test.sh` (24/24) |
| `--check` mode; both monitors SKIP loudly instead of lying | `sync-skills…`, `vendor-myclickup.sh` |
| `just check-upstreams` — both boundaries, one command, called by `test-offline` | `justfile` |
| Stale tier counts corrected (57/28 -> 40/17, 27 -> 38, 29 -> 58) | `docs/index.md` |

## Deliberate consequence: `test-offline` is red

`vendor-check` reports the myclickup wheel at 0.3.0 against source 0.4.0. That
drift was always there; only its visibility is new. Clearing it means
`just vendor-myclickup` -> `just build` -> `just recreate-all`.

Note `vendor-check` compares the **build context**, so going green there does not
mean running containers carry the new wheel. Nothing is broken meanwhile: the
vendored 0.3.0 wheel already contains `set-status`, verified by unzipping it.

Muting the check is not the fix. Muting is how the original drift happened.

## 5. Open

1. **myclickup reply** — `work/0011-allowlist-reconciliation/handoff-from-sandbox.md`.
   Corrects two records claiming `Bash(myclickup update:*)` is allow-listed when it
   never was, and asks back: of the three commands added between 19 and 22, are any
   writes? If so this repo's reads-only list needs review. No answer as of
   `myclickup@b373412` — that repo's head is still the commit that sent the handoff.

## 6. Closed since — step 8, and the agentic-conventions exchange

**Step 8 is closed, on all three profiles rather than the one asked for.** Each of
`nranthony` / `fluidmomenta` / `therapod`, live containers (Claude Code 2.1.231):
`claude plugin list` → one `myconv@skills-dir` **0.3.0**, `✔ loaded`; exactly one
nested `skills` dir; five skills; top-level `~/.claude/skills` holds only
`audit-sandbox`, `myclickup`, `myconv`, `web-read` — no bare `make-plan`/`wrap-up`
twins. `diff -r` against `sandbox_templates/skills/myconv` is silent for all three,
and no `*.bak*` sits beside them.

**The honest limit, and it is theirs, stated first:** this proves no phantom
*loads* now. It cannot prove they were ever loaded rather than merely on disk — the
containers were recreated onto a fresh image in between and that evidence went with
the old ones. Unrecoverable. It answers "is the fix real", not "what did the old
state do".

**They closed the exchange** — `agentic-conventions@c7ae832`, work/0013 archived, so
the thread now reads at `work/archive/0013-cli-first-clickup-skills/`
(`handoff-revendor-close.md`).

| Item | Outcome |
|---|---|
| §4 `variants` trap | **Fixed.** `justfile:121` is `diff -r -x variants …`, reason written above the recipe. Fixture-verified both ways: the stripped `variants/` goes silent, a real one-line drift still exits 1 |
| §6 `.claude/skills/` | **Kept, deliberately** — it is what makes the canonical bodies load as *project* skills there, so an edit is exercisable in the same session. Recorded in their AGENTS.md; retiring it now needs an ADR |
| §5 `sync-plugin` | Left copy-only on purpose; `check-plugin-sync` diffs both ways and exits 1, so the tier-4 shape is detected and needs a human delete |
| §3.10 | Nothing to change — `clickup-report`'s SKILL.md already tells the runner to answer the permission prompt. The owner's writes-keep-prompting decision needs no edit there |

Two things they gave back that are worth keeping here:

- **The `variants` hole is only half fixed, and the unfixed half is the consumer
  path.** `just sync-plugin` copies wholesale, so the first `variants/` they ship
  rides into the *plugin payload* and on to marketplace consumers. Our container
  path is safe because our sync strips it; nothing protects a consumer who is not
  us. Recorded against their `work/0003`, which is the item that would create one.
- **`check-vendored` can never run from inside one of our containers.**
  `.sandbox-repo.local` holds a host path that is not mounted, so in-container
  `just check` takes the SKIP branch on *every* run. Host-side is the only place
  that boundary is actually watched — which makes the loud `[SKIP]` load-bearing
  rather than cosmetic.

One asymmetry left alone: `-x variants` excludes any entry named `variants`, while
our sync strips only *directories* so named. A file called `variants` would ship and
the check would ignore it. Noted, not worth a guard.

## Decisions taken by the owner during this thread

- **ClickUp writes keep prompting.** `set-status` is not being allow-listed; the
  reads-only posture at `claude-settings.json:44` stands.
- **`.claude/skills/` in agentic-conventions** — retiring it was raised as the last
  instance of the "kept the old mechanism when the new one arrived" pattern. Left as
  analysis in the handoff, not actioned; it is the cheapest copy in the chain and is
  not what has been biting.
