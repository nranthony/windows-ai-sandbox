# ADR-0005 — Skill templates are the source of truth; profile copies are a derived cache

- **Status:** Accepted
- **Date:** 2026-08-10
- **Supersedes:** nothing. Changes the seeding semantics introduced with
  `sandbox_templates/skills/` (2026-07-04).
- **Affects:** `scripts/profile.sh` (`ensure_state`, `reset-skills`),
  `sandbox_templates/skills/`, the sibling `macolima` repo, and the two
  downstream handoffs that instruct operators to run `reset-skills`
  (`agentic-conventions` work/0005, `myclickup` work/0001 task 6).

## Context

Skills were seeded **create-only**: `up` copied a template skill into
`~/.ai-sandbox/profiles/<p>/claude-home/skills/<name>/` only when it was
missing, and `reset-skills` force-refreshed it after moving the existing copy
aside as `<name>.bak.<stamp>`. Both behaviours existed to protect one thing: a
local, in-container edit to a seeded skill.

Three findings, all from 2026-08-10, undermine that trade:

1. **Nothing is being protected.** All three live profiles contained exactly the
   template set (`audit-sandbox`, `web-read`, `make-plan`, `wrap-up`) plus two
   backups. No profile carried a hand-tuned skill. The feature guards a use case
   nobody exercises.
2. **Create-only *causes* drift.** Because `up` never reconciles, a template edit
   reaches a profile only if someone remembers `reset-skills`. Upstream measured
   the vendored `make-plan`/`wrap-up` copies 6 and 34 lines behind their source;
   the same mechanism kept every profile 11 days behind `audit-sandbox`.
3. **A backup inside the scanned directory is not inert.** `~/.claude/skills/` is
   scanned for both loose skills and skills-dir plugins (a subdirectory
   containing `.claude-plugin/plugin.json` auto-loads as `<name>@skills-dir`).
   Verified in-container (claude 2.1.223): with `probeconv/` and
   `probeconv.bak.<stamp>/` both present, `claude plugin list` **loaded the
   backup** and reported the fresh copy `✘ Not loaded — same plugin name`. For
   loose skills the effect is subtler — two live skills declaring one `name:`,
   distinguished only by directory. Every profile here was carrying an
   `audit-sandbox.bak` whose description still directed the tier-3 audit skill to
   cross-reference "the staged CLAUDE.md", a file `stage-audit-package.sh` does
   not put in the audit package. A stale copy was mis-instructing the judgment
   layer over the security probes.

## Decision

**`sandbox_templates/skills/` is the source of truth. A profile's
`claude-home/skills/` is a derived cache, reconciled on every `up`.**

1. **Converge, don't seed.** `ensure_state` replaces any copy that differs from
   its template. A template edit reaches every profile on the next `up`; a
   profile can no longer lag.
2. **No backups, ever, inside the scanned directory.** Every seeded skill is a
   copy of a git-tracked file, so git is the backup. `reset-skills` keeps working
   but takes none — it is now just "converge without touching the container".
3. **Overwrites and prunes both WARN.** Silent reconciliation would trade one
   invisible failure for another. A divergent copy names itself before being
   replaced; every prune names what it removed and why.
4. **Pruning is scoped, never a mirror.** Only `*.bak.*` and names recorded in
   `claude-home/skills/.sandbox-seeded` (written by convergence) are removed.
   Claude Code's own `claude plugin init` scaffolds into `~/.claude/skills/<name>/`,
   so "delete anything not in the template" would destroy an agent's own plugin.
   An unrecognised directory is reported and left alone.
5. **Per-profile variation has a different home.** Personal scope is converged
   and not a customisation surface. Intentional per-repo variation belongs in
   that repo's `.claude/skills/` (project scope, git-tracked); intentional shared
   variation belongs upstream in the template.

## Consequences

- A local edit to a seeded skill is destroyed on the next `up`, with a warning.
  That is the intended trade and the reason the warning is not optional.
- The host→profile drift axis disappears. The only staleness left is
  vendored-tree-vs-upstream, which the vendoring scripts' own freshness checks
  cover.
- Removing a skill from the template tree removes it from every profile — the
  template becomes the single lever for both addition and retirement.
- Downstream instructions simplify: "run `reset-skills` to pick up the new
  skill" becomes "run `up`". Both handoffs that carry that step are affected.
- Seeding a **skills-dir plugin** through this path becomes safe. It was not:
  the second `reset-skills` would have activated the previous version.
- `scripts/profile-skills.test.sh` (19 checks, offline) locks the two
  behaviours whose absence caused the defects: backups are pruned, and unmanaged
  directories are not.
- `profile.sh` is security-sensitive, so this change carries the AGENTS.md
  protocol. The pruning is a deletion under `~/.ai-sandbox` — bounded to
  `*.bak.*` and manifest-recorded names, both reproducible from git.

## Alternatives rejected

- **Relocate backups to `claude-home/backups/skills/`.** The first fix
  considered, and it does resolve the name race. Rejected as the weaker version:
  it preserves state that is reproducible from git, needs a new retention sweep
  in `clean` (nothing pruned skill backups, so they accumulated indefinitely),
  and leaves create-only drift — the actual disease — untouched.
- **Keep create-only, add a drift report.** Reporting a divergence a human must
  then act on is how the 11-day-stale copies survived.
- **Mirror the template exactly.** Simplest to implement, and it deletes
  `claude plugin init` output. Rejected on that alone.
