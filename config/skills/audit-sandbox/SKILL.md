---
name: audit-sandbox
description: Run a read-only isolation audit of THIS windows-ai-sandbox container — runs the structured audit script (~80 deterministic probes), cross-references findings against documented invariants in CLAUDE.md, and writes a markdown report + raw JSON under ~/.claude/audits/. Use when the user asks to "audit the sandbox", "verify hardening", "check sandbox isolation", "self-audit", or after a known sandbox config change. Requires the host-side helper to have staged the audit package — if /workspace/temp_audit_package/ is missing, tell the user to run `scripts/profile.sh <profile> audit --stage-only` from the host first.
---

# audit-sandbox — in-container isolation audit

This skill runs the windows-ai-sandbox self-audit. It does **not** duplicate the
audit spec — that lives at `/workspace/temp_audit_package/CLAUDE.md` (a
snapshot of the canonical sandbox documentation) once the host-side helper has
staged it. This skill body is the entry point; the staged file is the
authoritative reference for invariants.

The audit is structured around three tiers:

- **Tier 1** (`scripts/verify-sandbox.sh`) — fast tripwire, ~20 pass/fail
  checks. Runs as a sanity check.
- **Tier 2** (`scripts/audit/audit.sh`) — comprehensive structured probes,
  emits one JSON document covering identity / seccomp / fs / network /
  proxy / settings / env (~80 findings).
- **Tier 3** (you) — judgment over the JSON: real drift vs. tripwire bug,
  cosmetic vs. functional, recommended hardening diffs.

## Steps

1. **Prerequisite check.** Confirm `/workspace/temp_audit_package/` exists
   and contains `scripts/audit/audit.sh` plus `CLAUDE.md`. If either is
   missing, stop and tell the user:
   "The audit package isn't staged. From the host, run
   `scripts/profile.sh <profile> audit --stage-only` and then re-invoke
   this skill (or just `scripts/profile.sh <profile> audit` to do both)."
   Do **not** improvise the audit from memory — the staged package is the
   authoritative config snapshot for this profile.

2. **Resolve the profile name.** Use `$PROFILE` (set by compose) or, as
   fallback, parse it out of `/etc/hostname` (the agent container is
   `ai-sandbox-<PROFILE>`). You'll need the profile name to populate
   `<PROFILE>` in output filenames.

3. **Run the structured audit.**
   ```sh
   bash /workspace/temp_audit_package/scripts/audit/audit.sh > /tmp/audit.json
   ```
   This emits one JSON document. Read it.

4. **Read the staged CLAUDE.md** focused on "Security Posture", "Important
   Notes", and the relevant section for any DRIFT/UNKNOWN you saw in the
   JSON. The staged copy is the snapshot the audit was run against; the
   live repo CLAUDE.md may have drifted.

5. **Write the markdown report.** Save to:
   - `/root/.claude/audits/$(date -u +%Y-%m-%d)-<profile>-report.md`
   - `/root/.claude/audits/$(date -u +%Y-%m-%d)-<profile>-audit.json` (copy of `/tmp/audit.json`)

   The report should:
   - Open with a one-paragraph summary citing the verdict counts.
   - Be organized by JSON `section` (identity, mac, seccomp_static,
     seccomp_runtime, fs, network, proxy, settings, env).
   - For every non-OK finding, render judgment: is this real drift, a
     tripwire artifact, or a known weak spot? Reference CLAUDE.md.
   - End with a "Recommended hardening" section listing tight, specific
     diffs (file path + minimum change) for any real drift.

6. **Print the output paths on completion**:

   ```
   Report:   /root/.claude/audits/<stamp>-<profile>-report.md
             host: ~/.ai-sandbox/profiles/<profile>/claude-home/audits/<stamp>-<profile>-report.md
   JSON:     /root/.claude/audits/<stamp>-<profile>-audit.json
             host: ~/.ai-sandbox/profiles/<profile>/claude-home/audits/<stamp>-<profile>-audit.json
   audit.sh: /workspace/temp_audit_package/scripts/audit/audit.sh
   ```

## Hard rules

- **Read-only.** Do not install packages, change persistent state outside
  `/tmp` and the prescribed output dir, or attempt any container-escape
  probe.
- **No outbound traffic to third parties.** Egress already goes through
  the Squid allowlist. The structured audit's `network` probes
  intentionally test a not-on-allowlist domain to confirm the proxy
  blocks it — that's the only allowed deviation and the script already
  does it.
- **Don't replicate the script's checks.** Your value here is judgment
  over the JSON output, not re-running probes. If an UNKNOWN needs
  disambiguation, ONE targeted Python snippet in `/tmp` is fine — don't
  recreate the audit ad-hoc.
- **If a finding requires a state-changing test to confirm**, describe
  the test and the expected signal in the report instead of running it.
  Flag it for the user's review.

## windows-ai-sandbox–specific gotchas (vs. macolima)

- **Container runs as root (UID 0)**. uid_map line 1 should read
  `0 1000 1` — that's the rootless Docker userns=host invariant. The
  `identity.uid` and `identity.gid` checks expect 0, not 1000.
- **Hook script is writable by the agent** because the agent IS root.
  `settings.hook_immutable` correctly emits **WEAK** with rationale, not
  DRIFT — kernel write-protect doesn't apply; the matcher/tamper rules and
  image rebuild are the enforcement layer (see
  `docs/deny-destructive-hook-plan.md`).
- **AppArmor may be absent** under rootless Docker on WSL2 —
  `mac.apparmor_profile` will emit WEAK. seccomp + cap_drop + userns are
  the boundary; AppArmor is bonus.
- **`/dev/dxg` is expected** in the dev inventory (WSL2 GPU device).
- **No virtiofs.** WSL2 bind mounts are ext4 by default; the macolima
  named-volume gotcha doesn't apply.
