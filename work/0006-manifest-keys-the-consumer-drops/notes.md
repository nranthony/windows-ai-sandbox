# 0006 — §3 re-investigation notes (2026-08-24, offline, read-only)

Per plan §5 step 1. All checks re-run against the depot channel resolved via
`.depot-dir.local` (never a hard path — see AGENTS.md).

## §3.1 — manifest shape

`schema = 1`, unchanged. Two artifacts still: `myclickup` (`wheel+skill`),
`myconv` (`plugin`). `myconv` is now `0.6.0 @ 1b0d8848` — this repo's own
consumer state is current: `VENDORED.lock` matches, `scripts/vendor-tools.sh
--check` is fully green, 0 artifacts reported `HASH-ONLY`. No schema bump, so
this item is not superseded by §3.1's escape hatch.

## §3.2 — does the consumer still drop anything?

Probe reproduces exactly: one line,
`DROPPED myconv asserts = {'myclickup': '>=0.3.0'} (type dict)`. Same single
dict-valued key as 2026-08-17; no new dropped key has appeared.

## §3.3 — has the producer's key set or checking moved?

Producer key order is byte-identical to the 2026-08-17 capture. `_verify_asserts`
is intact and unweakened, at `depot/bin/channel.py:419`, called from
`cmd_verify` at `:367`. No commits to `channel.py` since 2026-08-16 — the
producer side has not moved at all since this item was raised. §2.3's first
mitigation (the producer checks `asserts` even though this consumer does not)
still holds.

## §3.4 — new artifacts or kinds?

None. `paperbridge` is still explicitly "not a channel member yet" per depot
AGENTS.md — no third `kind` has appeared, so §4 Option A would not yet need a
new per-kind allowlist entry, and `member_pointer` needs no new `source_repo`
line.

## §3.5 — has `vendor-tools.sh` itself moved?

Unchanged since before this item was raised. `manifest_flat` at line 121 (now
shifted by this change); the `isinstance` type test with no `else` sat at what
was lines 133/135 pre-fix. Confirmed the fix belongs exactly where §2 said it
did.

## §3.6 — has the fixture gained a dict-valued key?

No — the fixture manifest carried no dict-valued key and no `asserts` key at
all. 57/57 was green over that gap, confirming §2.3/§3.6's point that an empty
DROPPED result does not mean the item is closed. Fixed by this change: the
fixture's `myconv` artifact now carries `asserts` (dict) and a bool key, and
65/65 covers both directions (known shapes still extract; the unknown/dict
shape reports and does not fail).

## §3.7 — is there now an authoritative contract doc?

No. No `docs/adr/` entry on the depot side addresses a manifest key contract,
and myclickup's ADR-0014 (the cross-repo boundary ADR) does not define one
either. Nothing found displaces this file's own §4 as the decision point.

## §2.1 — do all four listed shapes reproduce, plus anything new?

All four reproduce empirically against the live manifest / a constructed
probe: dict dropped silently, float dropped silently, `list[dict]` stringifies
via Python `repr` into the flat table (worse than dropped — looks like real
data), bool renders in Python spelling (`True`/`False`) rather than TOML's.

A **fifth** shape the original table missed: TOML date/datetime values
(`datetime.date` / `datetime.datetime` after `tomllib.load`) are also silently
dropped by the same `else`-less branch. No live exposure — no manifest key of
this shape exists today; added to the plan's §2.1 table for completeness since
the fix needs to cover it too.

## Decision

Per plan §4, provisional lean was **B** ("no key is silently lost; unknown key
REPORTS, does not fail"), conditional on §3 not showing the producer-side
check weakened or a second consumer appearing. Neither trigger fired:
`_verify_asserts` is unweakened (§3.3), and no second consumer or new kind has
appeared (§3.4). Cadence evidence *adds* to the case for B rather than
complicating it: depot AGENTS.md now states additive publishes need "no schema
or tooling change" on the consumer side — exactly the non-breaking behavior B
provides and A would violate on the next such publish.

**Decision: Option B.** No key is silently lost; an unknown/unrepresentable
value reports via a `[NOTE]` line naming the artifact, key, and TOML type;
never fails, never emits `repr` garbage. No ADR needed — per plan §4, only A or
C would warrant one.
