I'd like your help auditing the isolation posture of a development sandbox
I built and own. You are currently running inside it. This is a self-audit
of my own system — the output is a report I'll use to tighten my own
configuration. Nothing here targets a third party, and nothing leaves
this machine.

This repo is a **multi-profile** sandbox: each profile is its own Docker
Compose project named `macolima-<profile>`, with container
`claude-agent-<profile>`, its own networks, named volumes, and state
dir under `profiles/<profile>/`. Profiles run concurrently. Resources
from sibling profiles on the same Docker daemon are **expected**, not a
leak — scope your audit to the profile named below.

You are running inside `claude-agent-<PROFILE>`. Your working directory
inside the container is `/workspace`, which is a bind of the host path
`/Volumes/DataDrive/repo/<PROFILE>` — that's the *target project* for
this profile, not the sandbox config.

**Important**: the sandbox config repo (`macolima`) lives at
`/Volumes/DataDrive/repo/nranthony/macolima` on the host and is **not
mounted into the container**. To make its config available for this
audit, I'll stage a read-only snapshot into
`/workspace/temp_audit_package/` using the host-side helper
`scripts/stage-audit-package.sh <PROFILE>`. Everything under that
directory is a copy for the audit only; do not edit it, and ignore
`temp_audit_package/` when enumerating `/workspace` contents as a
general "target project" review.

Expected contents of `/workspace/temp_audit_package/`:

- `CLAUDE.md`          — invariants, gotchas, rationale. Load-bearing;
                         read fully.
- `Dockerfile`         — preinstalled tool inventory (do not attempt
                         installs)
- `docker-compose.yml` — runtime config (caps, networks, mounts, env,
                         tmpfs, per-profile `container_name`)
- `seccomp.json`       — seccomp allowlist; review white-box before any
                         syscall probing
- `proxy/allowed_domains.txt`, `proxy/squid.conf` — egress policy
- `scripts/verify-sandbox.sh` — legacy in-container tripwire. **Run
                         this first** (`bash
                         /workspace/temp_audit_package/scripts/verify-sandbox.sh`)
                         but treat the following asserts as **known
                         stale** — the real invariants have moved on,
                         and a FAIL/WARN on any of these is *expected*,
                         not drift:
                           • `rootfs read-only` — `read_only: true` was
                             removed (broke VS Code Dev Containers).
                             Writable rootfs is now correct; non-root +
                             `cap_drop: ALL` is the boundary.
                           • `bubblewrap present` — `bwrap` + `socat`
                             were deliberately uninstalled (Claude Code's
                             bwrap sandbox can't run here; `socat` was a
                             raw-TCP exfil channel). Absence is correct.
                           • `proxied request to allowed domain works`
                             using `https://api.github.com` — in
                             autonomous mode `.github.com` is commented
                             out in `allowed_domains.txt`, so this WARNs
                             by design. Use `https://api.anthropic.com`
                             as the reliable proxy-success probe.
                         The other asserts (non-root, seccomp mode 2,
                         caps dropped, direct egress blocked, disallowed
                         domain blocked, claude CLI present) are still
                         valid. Use those as baseline; re-verify
                         everything else from scratch.
- `scripts/setup.sh`, `scripts/profile.sh` — for reference only; their
                         host-side equivalents do things like
                         `setup.sh <p> --verify`. You can't run them
                         from inside the container (no docker CLI); if
                         you want the output, ask me.

Your job is to verify that the runtime reality inside the container
matches what those files describe. You have full access to runtime
state: `/proc`, `/sys`, mount table, env, caps, devices, network
config, seccomp behavior via small probes in `/tmp`. Cross-reference
that against the staged config — drift is the interesting finding.

This is verification, not discovery from scratch. For each documented
invariant, confirm it holds at runtime; drift is the interesting
finding. Prefer reading config and /proc over running probes.

Environment context:
- Host: macOS
- VM: Colima (Lima-based, virtiofs mounts). Expect the virtiofs mount
  tag `/Volumes/DataDrive` visible from inside the VM.
- Container: Ubuntu 24.04, agent runs as UID 1000 ("agent")
- Profile under audit: `<PROFILE>` (container `claude-agent-<PROFILE>`,
  compose project `macolima-<PROFILE>`)
- Optional sibling containers (gated behind compose `profiles:`):
  `postgres-<PROFILE>` / `mongo-<PROFILE>` on `sandbox-internal`. Check
  whether they're up and include them in scope if so.

Ground rules (read-only audit):
- Read-only enumeration. Do not modify files outside /tmp.
- Do not install packages, add users, or change persistent state.
- No destructive probes: no fork bombs, no filesystem fill, no killing
  processes you didn't start, no kernel panics.
- No outbound traffic to third parties. Egress already goes through a
  local Squid proxy with an allowlist; stay within that. You MAY
  intentionally request a domain NOT on the allowlist for the sole
  purpose of confirming the proxy blocks it — that's a local control
  test of my own infrastructure.
- If confirming a finding would require a state-changing action,
  describe the test and the expected signal instead of running it,
  and flag it for my review.
- Stop and ask before anything you're unsure about.

Scope — verify and report on:

1. Identity & privileges: uid/gid, effective and bounding capabilities
   (capsh --print or reading /proc/self/status), no_new_privs, sudo
   presence, **full SUID/SGID inventory** (`find / -perm /6000 -type f
   2>/dev/null`). Expected **for the agent container**: UID 1000 "agent",
   empty capability sets, no_new_privs=1, no sudo. A small set of stock
   Ubuntu SUID binaries (`su`, `mount`, `umount`, `passwd`, `chfn`,
   `chsh`, `gpasswd`, `newgrp`, `unix_chkpwd`, etc.) is expected and
   neutralized by no_new_privs + cap_drop: ALL — list them, flag anything
   outside that stock set as DRIFT. Note: `egress-proxy`
   legitimately holds `CAP_SETUID`+`CAP_SETGID` (Squid starts as root
   then drops to `proxy`); that is NOT drift. `NET_BIND_SERVICE` is
   explicitly not granted to Squid (port 3128 is unprivileged).
2. MAC: AppArmor/SELinux status and any applied profile.
3. Seccomp — white-box first: read ./seccomp.json and note which syscall
   classes it allows/denies and its default action. Then spot-check at
   runtime. Confirm:
   - Syscalls that must be **blocked**: `unshare(CLONE_NEWUSER)` → EPERM.
   - Syscalls that must return a **specific errno** for glibc fallback:
     `clone3` → **ENOSYS (38), not EPERM**. If EPERM, glibc won't fall
     back to `clone()` and threading breaks silently — flag this
     specifically.
   - Syscalls that must **work**: `mknod`/`mknodat` (mkfifo, gitstatusd),
     `getpgid` (bash job control), `rseq` (glibc thread init),
     `pidfd_open` / `pidfd_send_signal` / `pidfd_getfd` (modern process
     mgmt), `close_range` (Go/C++ runtimes), and the full xattr family
     (`getxattr`, `setxattr`, `lgetxattr`, `fgetxattr`, `removexattr`,
     `listxattr` and their `l*`/`f*` variants — tar/apt silently fail
     without them).
   Use small throwaway probes in /tmp.
4. Filesystem: mount table, ro vs rw, bind mounts from the host, SUID/SGID
   binaries, world-writable paths. Verify:
   - `~/.claude.json` is a **single-file bind**, **mode 644**, valid JSON
     (at minimum `{}`). Single-file binds on Colima virtiofs don't UID-
     remap, so 600 would appear root-owned and unreadable to agent.
   - `~/.claude/.credentials.json` (if present) is **mode 600**. This
     works *because* it sits inside a **directory** bind (`.claude/`),
     which uses the remap path. Do not "normalize" the two.
   - `~/.config` is a per-profile **directory** bind (agent-writable),
     holds `gh/`, `glab-cli/`, and `git/config`.
   - `~/.gitconfig` is **NOT** bind-mounted. `GIT_CONFIG_GLOBAL` should
     be set to `/home/agent/.config/git/config` in env. Single-file
     `.gitconfig` bind → EBUSY on `rename()` across virtiofs.
   - `~/.vscode-server` is a **named Docker volume**, not a virtiofs
     bind. The named volume for this profile is
     `macolima-<PROFILE>_vscode-server`.
   - tmpfs mounts under `/home/agent/` (`.local`, `.npm-global`) must
     carry `uid=1000,gid=1000,mode=0755`. A bare tmpfs comes up
     root:755 and shadows the Dockerfile-created dir — easy drift.
     `/tmp` and `/run` are system dirs; root-owned is correct there.
   - Base image: confirm the running image digest matches the
     `FROM ubuntu:24.04@sha256:...` pin in Dockerfile (drift = local
     retag).
5. /proc and /sys exposure: masked paths, readability of /proc/kcore,
   /proc/sys/kernel/*, /sys/kernel/*.
6. PID namespace & process visibility: PID of init as seen from the
   container, total visible processes, whether any host/VM processes
   leak in.
7. Devices: /dev contents; any host devices passed through.
8. Cgroups: v1 vs v2, visible limits, writable controllers.
9. Network & egress: interfaces, routes, whether host netns is shared,
   reachable hosts on the container's bridge. Then confirm egress
   control:
   (a) a domain on `proxy/allowed_domains.txt` succeeds via proxy,
   (b) a domain NOT on the list is refused by the proxy,
   (c) **direct egress bypassing the proxy fails** — attempt a raw TCP
       connect to e.g. `1.1.1.1:443` or any hostname other than
       `egress-proxy` without `HTTPS_PROXY` set. Expect network
       unreachable because `sandbox-internal` is `internal: true`. Do
       NOT test (c) through a proxy-aware curl — that produces a false
       OK.
   (d) Enumerate `proxy/allowed_domains.txt` and flag any broad
       wildcards (e.g. `*.microsoft.com`) as **WEAK** per CLAUDE.md's
       prohibition.
   (e) If `postgres-<PROFILE>` / `mongo-<PROFILE>` are up: confirm they
       are reachable from the agent by hostname (`postgres:5432`,
       `mongo:27017`), sit only on `sandbox-internal`, and have no
       `ports:` block binding to `0.0.0.0`. `127.0.0.1:<port>` binding
       is acceptable if explicitly uncommented (documented GUI access
       path); flag it so I can confirm intent.
   (f) Note that `gh`/`glab` OAuth **browser** flow is intentionally
       broken (no published ports, `sandbox-internal` is internal).
       Token flow is the documented path — do NOT report this as drift.
10. Colima/VM boundary: identify signals that this is a Lima/Colima VM
    (virtiofs mount tags, `/Volumes/DataDrive` visibility, /mnt/lima-*
    paths, kernel hints) and note what — if anything — is visible about
    the VM or host from inside. Do not attempt to cross the VM boundary.
11. Kernel: uname -a. CVE enumeration is out of scope (no internet,
    and the kernel belongs to the VM, not this container).
12. Claude Code harness config: `~/.claude/settings.json` is expected to
    contain `"sandbox": {"enabled": false}`. This disables Claude Code's
    internal bwrap-based Bash sandbox, which cannot function inside this
    container because it requires unprivileged user namespaces (which
    are correctly blocked by the seccomp filter — see §3). The container
    is the security boundary; bwrap-inside-the-container would be
    redundant nesting that blocks Bash entirely. Presence of this
    setting is **OK**, not drift. Absence means either (a) the profile
    predates the template and needs the key added, or (b) the template
    was overridden — flag which.

13. Secrets hygiene:
    - Env vars, mounted config, anything credential-like in the agent's
      home. Redact values in the report.
    - **SSH agent forwarding**: check `env | grep SSH_AUTH_SOCK` and
      `ls -la /tmp/ssh-* /tmp/vscode-ssh-* 2>/dev/null`. The compose
      file does not forward the host SSH agent, but VS Code Dev
      Containers can inject `SSH_AUTH_SOCK` per user setting
      (`remote.SSH.enableAgentForwarding`). Presence = the agent can
      authenticate as you to anything your host keys reach, bypassing
      the sandbox network identity — flag as **WEAK** with the socket
      path so I can disable the VS Code setting.
    - **Known weak spot**: if DB siblings are up, `db.env` injects
      `POSTGRES_USER`/`POSTGRES_PASSWORD` and `MONGO_INITDB_ROOT_*`
      into the agent as ambient env — these are DB **superuser**
      credentials. CLAUDE.md flags this as a TODO for least-privilege
      split (planned: `agent_rw` role with CRUD-only grants). Report
      this as **expected WEAK**, not DRIFT, so it shows up in the
      hardening list.
    - Host-side: confirm `profiles/` is gitignored and `profiles/<p>/db.env`
      is not accidentally readable beyond the intended scope. I can
      check host-side perms myself if you describe what to look at.

Output a single markdown report:
- One section per area above.
- Each invariant tagged OK / DRIFT / WEAK / UNKNOWN, with expected
  vs. observed state.
- A "Recommended hardening" section with concrete, minimal changes
  (file + line where possible).
- A chronological command log, outputs trimmed to what supports a
  finding, so I can reproduce.

Before running anything:
1. Confirm `/workspace/temp_audit_package/` exists and lists the
   expected files; if anything is missing, tell me so I can re-stage.
2. Run `bash /workspace/temp_audit_package/scripts/verify-sandbox.sh`
   and summarize which invariants it already covers. Explicitly call
   out any of the three known-stale asserts above (rootfs RO /
   bubblewrap present / github.com via proxy) so I can see you
   recognized them as legacy rather than drift.
3. Summarize your plan in one paragraph: what you'll check beyond
   verify-sandbox.sh, what local probes you intend to run in `/tmp`,
   and anything you want me to approve up front.
4. Wait for my go-ahead.
