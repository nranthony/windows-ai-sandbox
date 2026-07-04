# Skill: Hardening Verification & Audit

Three tiers, cheapest first. Run tier 1 after every config change touching a
security-sensitive file (see AGENTS.md); tier 2 before merging such a change.

| Tier | Cost | What | When |
|---|---|---|---|
| 1 | ~3s | `scripts/profile.sh <p> verify` — tripwire, ~57 pass/fail/warn/N-A outcomes | every `up`, every sensitive change |
| 2 | ~10s | `scripts/profile.sh <p> audit` — ~80 structured probes → JSON in `~/.ai-sandbox/profiles/<p>/claude-home/audits/` | on demand / post config change |
| 3 | ~5k toks | agent reads the tier-2 JSON + staged SKILL.md, writes report.md (judgment only, no probe execution) | on demand |

## Tier 1 — tripwire

```bash
scripts/profile.sh <profile> verify     # streams scripts/verify-sandbox.sh via stdin
```

Expected on BOTH substrates: uid_map `0 1000 1`, CapEff=0, NoNewPrivs=1,
Seccomp=2, direct internet blocked, api.anthropic.com reachable via proxy,
example.com blocked, ssh/socat/bwrap absent, deny-destructive hook present
and blocking.

Substrate-specific: GPU checks PASS on WSL2+GPU, report `N/A` on bare Linux
(both correct); one-of-two GPU artifacts = WARN (overlay drift). A uid_map of
`0 0 ...` is a hard FAIL — rootful Docker, the sandbox boundary is absent.

## Tier 2 — structured audit

```bash
scripts/profile.sh <profile> audit                # stage + run, JSON to host
scripts/profile.sh <profile> audit --stage-only   # just stage
scripts/profile.sh <profile> audit --clean        # remove staged package
```

Stages repo config to `/workspace/temp_audit_package/` (via
`scripts/stage-audit-package.sh`) so probes can read seccomp.json /
squid.conf / claude-settings.json, then runs `scripts/audit/` probes.
Verdicts: OK | DRIFT | WEAK | UNKNOWN | N/A | INFO. `fs.wsl_driver_shim`
is `N/A` on bare Linux.

## Tier 3 — agent judgment

Inside an attached session, after tier 2. The staged skill at
`/workspace/temp_audit_package/skills/audit-sandbox/SKILL.md` instructs the
agent to cross-reference the JSON against the staged config and write
`report.md` next to the JSON. No probe execution.

## Image CVE scan (host)

```bash
scripts/trivy-scan.sh         # config + secret + image (default)
scripts/trivy-scan.sh image   # image CVEs only
```

Accepted findings live in `.trivyignore.yaml`; every entry carries
`expired_at` so it re-surfaces.

## The deny-destructive hook

`sandbox_templates/claude/hooks/deny-destructive.sh` (baked into the image at
`/usr/local/lib/claude-hooks/`). After editing it, run its test suite:

```bash
bash sandbox_templates/claude/hooks/deny-destructive.test.sh   # expect 35/35
```

Design: `docs/deny-destructive-hook-plan.md`.
