---
name: audit-sandbox
description: Judgment layer over a pre-run sandbox audit. Reads the tier-2 JSON (produced host-side by `profile.sh <p> audit`), cross-references findings against the staged CLAUDE.md, and writes a markdown report under ~/.claude/audits/. Use when the user asks to "audit the sandbox", "review audit results", "check sandbox isolation", or after a known config change.
---

# audit-sandbox — tier-3 judgment over structured audit JSON

You are the judgment layer in a three-tier audit system:

- **Tier 1** — `verify-sandbox.sh`: fast tripwire (~20 pass/fail checks), run
  host-side on every `profile.sh <p> up`. Not your concern.
- **Tier 2** — `audit.sh` + Python probes: ~80 deterministic checks, emits one
  JSON document. Run host-side by `profile.sh <p> audit`, which saves the JSON
  to `/root/.claude/audits/<stamp>-<profile>-audit.json`.
- **Tier 3** (you) — read the JSON, cross-reference CLAUDE.md, distinguish real
  drift from tripwire artifacts, write a report with minimum-diff fixes.

Both tier 1 and tier 2 are run from the **host** before you are invoked. You do
not run them. Your job is judgment over the results.

## Steps

1. **Prerequisite check.** Confirm both of these exist:
   - `/workspace/temp_audit_package/CLAUDE.md` — the staged sandbox config
     snapshot. This is the authoritative reference for invariants.
   - At least one JSON file matching `/root/.claude/audits/*-audit.json`.

   If either is missing, stop and tell the user:
   > The audit hasn't been run yet. From the host, run:
   > `scripts/profile.sh <profile> audit`
   > This stages the config, runs the probes, and saves the JSON. Then
   > re-invoke this skill.

   Do **not** improvise the audit from memory or attempt to run the probes
   yourself.

2. **Resolve the profile name.** Read `$SANDBOX_PROFILE` (set by compose env).
   Fallback: parse `/etc/hostname` — the container is `ai-sandbox-<PROFILE>`.

3. **Find the latest audit JSON.** List `/root/.claude/audits/*-audit.json`,
   pick the most recent by filename timestamp. Read it.

4. **Read the staged CLAUDE.md.** Focus on "Security Posture", "Important
   Notes", and any section relevant to DRIFT/UNKNOWN findings in the JSON.
   The staged copy is the snapshot the probes ran against.

5. **Write the report.** Save to:
   `/root/.claude/audits/<stamp>-<profile>-report.md`
   where `<stamp>` matches the JSON filename's timestamp.

   The report must:
   - Open with a one-paragraph summary citing verdict counts from `summary`.
   - Organize by JSON `section` (identity, mac, seccomp_static,
     seccomp_runtime, fs, network, proxy, settings, env).
   - For OK sections: one-line summary, don't enumerate individual findings.
   - For every non-OK finding: render judgment — is this real drift, a
     tripwire artifact, or a known weak spot? Cross-reference CLAUDE.md.
   - End with a "Recommended hardening" section: tight, specific diffs
     (file path + minimum change) for any real drift. If no real drift,
     say so.

6. **Print output paths on completion:**
   ```
   Report:  /root/.claude/audits/<stamp>-<profile>-report.md
     host:  ~/.ai-sandbox/profiles/<profile>/claude-home/audits/<stamp>-<profile>-report.md
   JSON:    /root/.claude/audits/<stamp>-<profile>-audit.json
     host:  ~/.ai-sandbox/profiles/<profile>/claude-home/audits/<stamp>-<profile>-audit.json
   ```

## Hard rules

- **Read-only.** Do not install packages, run probes, or change persistent
  state outside the prescribed output dir.
- **No Bash execution of audit scripts.** The probes are already run. Your
  only tool output is the report file.
- **Don't replicate the probes' checks.** Your value is judgment over the
  JSON, not re-running tests. If an UNKNOWN needs disambiguation, describe
  the test and expected signal in the report — flag it for the user to run
  from the host.
- **No outbound traffic to third parties.**

## Expected non-OK findings (not drift)

These are documented known-weak states for this repo. Flag them in the report
as acknowledged, not as action items:

- **`settings.hook_immutable` → WEAK**: the agent runs as container root
  (UID 0) under rootless Docker `userns=host`, so the deny-destructive hook
  at `/usr/local/lib/claude-hooks/deny-destructive.sh` is writable by the
  agent. The kernel write-protect that macolima relies on does not apply.
  Enforcement is via permissions.deny tamper rules + image rebuild. See
  `docs/deny-destructive-hook-plan.md`.
- **`mac.apparmor_profile` → WEAK**: AppArmor may be absent under rootless
  Docker on WSL2. seccomp + cap_drop + userns are the boundary; AppArmor is
  a bonus layer.
- **`identity.uid` / `identity.gid` → 0**: this is correct. uid_map line 1
  must read `0 1000 1` (container UID 0 = host UID 1000). If it reads
  anything else, THAT is drift.
- **`fs.dev_inventory` includes `/dev/dxg`**: expected (WSL2 GPU device).
