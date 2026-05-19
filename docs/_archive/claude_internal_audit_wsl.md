I'd like your help auditing the isolation posture of a development sandbox
I built and own. You are currently running inside it. This is a self-audit
of my own system — the output is a report I'll use to tighten my own
configuration. Nothing here targets a third party, and nothing leaves
this machine.

This repo is a **multi-profile** sandbox: each profile is its own Docker
Compose project named `ai-sandbox-<profile>`, with container
`ai-sandbox-<profile>`, its own networks, and per-profile state dir
under `~/.ai-sandbox/profiles/<profile>/` on the host. Profiles run
concurrently. Resources from sibling profiles on the same rootless Docker
daemon are **expected**, not a leak — scope your audit to the profile
named below.

You are running inside `ai-sandbox-<PROFILE>`. Your working directory
inside the container is `/workspace`, which is a bind of the host path
`~/repo/<PROFILE>` (i.e. `/home/<host-user>/repo/<PROFILE>`) — that's
the *target project parent* for this profile, not the sandbox config.

**Important**: the sandbox config repo (`windows-ai-sandbox`) lives at
`~/repo/sandbox/windows-ai-sandbox` on the host and is **not mounted
into the container**. To make its config available for this audit, I'll
stage a read-only snapshot into `/workspace/temp_audit_package/` using
the host-side helper `scripts/stage-audit-package.sh <PROFILE>` (or
equivalently `scripts/profile.sh <PROFILE> audit --stage-only`).
Everything under that directory is a copy for the audit only; do not
edit it, and ignore `temp_audit_package/` when enumerating `/workspace`
contents as a general "target project" review.

Expected contents of `/workspace/temp_audit_package/`:

- `CLAUDE.md`          — invariants, gotchas, rationale. Load-bearing;
                         read fully.
- `Dockerfile`         — preinstalled tool inventory (do not attempt
                         installs). Base image is NVIDIA CUDA
                         12.6.3-base-ubuntu24.04, digest-pinned.
- `docker-compose.yml` — runtime config (caps, networks, mounts, env,
                         tmpfs, per-profile `container_name`,
                         GPU device passthrough)
- `seccomp.json`       — seccomp allowlist; review white-box before any
                         syscall probing
- `proxy/allowed_domains.txt`, `proxy/squid.conf` — egress policy
- `config/claude-settings.json` — Claude harness permissions + hook
                         registration
- `config/hooks/deny-destructive.sh` — PreToolUse deny-list-bypass guard
- `scripts/audit/`     — the Tier-2 probe suite (~80 structured probes,
                         stdlib-Python). You may invoke individual
                         probes for verification but the JSON aggregate
                         is already produced host-side and lives under
                         `~/.ai-sandbox/profiles/<PROFILE>/claude-home/audits/`
                         (visible inside as `/root/.claude/audits/`).
- `scripts/verify-sandbox.sh` — Tier-1 in-container tripwire. **Run
                         this first** (`bash
                         /workspace/temp_audit_package/scripts/verify-sandbox.sh`).
                         All asserts here are current invariants for
                         this repo (unlike the macolima ancestor, no
                         known-stale asserts remain). Expected output
                         summary:
                           • uid_map `0 1000 1` (rootless userns=host)
                           • CapEff=0, NoNewPrivs=1, Seccomp=2
                           • direct internet blocked,
                             `api.anthropic.com` reachable via proxy,
                             `example.com` blocked
                           • `bwrap` / `socat` / `ssh` absent
                           • no `SSH_AUTH_SOCK`, no leaked
                             `~/.gitconfig`, no `credential.helper`
                             injection in `~/.config/git/config`
                           • deny-destructive hook present and wired
- `scripts/profile.sh`, `scripts/init-profile-state.sh`,
  `scripts/with-egress.sh`, `scripts/run-ephemeral.sh` — host-side
  drivers for reference only. You can't run them from inside the
  container (no docker CLI, sandbox-internal has no daemon socket); if
  you want their output, ask me.

Your job is to verify that the runtime reality inside the container
matches what those files describe. You have full access to runtime
state: `/proc`, `/sys`, mount table, env, caps, devices, network
config, seccomp behavior via small probes in `/tmp`. Cross-reference
that against the staged config — drift is the interesting finding.

This is verification, not discovery from scratch. For each documented
invariant, confirm it holds at runtime; drift is the interesting
finding. Prefer reading config and /proc over running probes.

Environment context:
- Host: Windows 11 → WSL2 Ubuntu 24.04 LTS (ext4, no virtiofs)
- Container engine: **rootless Docker** on the WSL distro, socket at
  `/run/user/1000/docker.sock`, `userns=host` (default rootless mode —
  NOT `userns-remap`).
- Container: Ubuntu 24.04 (via CUDA base), **agent runs as UID 0
  (root) inside the container**, which remaps to **host UID 1000** via
  the rootless user namespace. This is correct — non-root in-container
  would remap to host UID 100999 ("nobody") and break workspace
  writes. The boundary is `cap_drop: ALL` + seccomp + no-new-privileges,
  not the in-container UID.
- GPU: WSL2-native passthrough via `/dev/dxg` device + bind of
  `/usr/lib/wsl` + `LD_LIBRARY_PATH=/usr/lib/wsl/lib`. NOT `--gpus all`
  / nvidia-container-toolkit CDI (broken on WSL2 with toolkit ≥1.18;
  pinned to 1.17.8-1 host-side).
- Profile under audit: `<PROFILE>` (container `ai-sandbox-<PROFILE>`,
  compose project `ai-sandbox-<PROFILE>`).
- No DB siblings in this repo. If you see `postgres-*` / `mongo-*`
  containers, that's drift — they don't belong here.

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
   (`capsh --print` or reading `/proc/self/status`), `no_new_privs`,
   sudo presence, **full SUID/SGID inventory** (`find / -perm /6000
   -type f 2>/dev/null`). Expected **for the agent container**: UID 0
   (root) in-container with `/proc/self/uid_map` showing `0 1000 1`,
   empty effective/permitted/bounding cap sets (CapEff=0), no_new_privs=1,
   no sudo binary present (Dockerfile purges it). Stock Ubuntu SUID
   binaries (`mount`, `umount`, `su`, `passwd`, `chfn`, `chsh`,
   `gpasswd`, `newgrp`, `unix_chkpwd`, etc.) are expected — list them
   and flag anything outside that stock set as DRIFT; cap_drop:ALL +
   no_new_privs neutralizes them. Note: `egress-proxy` legitimately
   holds `CAP_SETUID`+`CAP_SETGID` (Squid starts as root then drops to
   `proxy`); that is NOT drift. `NET_BIND_SERVICE` is explicitly not
   granted (port 3128 is unprivileged).
2. MAC: AppArmor/SELinux status and any applied profile. (Under WSL2
   the host kernel typically has AppArmor available; the rootless
   daemon may or may not apply a profile.)
3. Seccomp — white-box first: read `seccomp.json` and note which
   syscall classes it allows/denies and its default action. Then
   spot-check at runtime. Confirm:
   - Syscalls that must be **blocked**: `unshare(CLONE_NEWUSER)` →
     EPERM (this is what stops bwrap-style nesting).
   - Syscalls that must return a **specific errno** for glibc fallback:
     `clone3` → **ENOSYS (38), not EPERM**. If EPERM, glibc won't fall
     back to `clone()` and threading breaks silently — flag this
     specifically.
   - Syscalls that must **work**: `mknod`/`mknodat` (mkfifo,
     gitstatusd), `getpgid` (bash job control), `rseq` (glibc thread
     init), `pidfd_open` / `pidfd_send_signal` / `pidfd_getfd`,
     `close_range` (Go/C++ runtimes), and the full xattr family
     (`getxattr`, `setxattr`, `lgetxattr`, `fgetxattr`, `removexattr`,
     `listxattr` and their `l*`/`f*` variants — tar/apt silently fail
     without them).
   Use small throwaway probes in /tmp.
4. Filesystem: mount table, ro vs rw, bind mounts from the host, SUID/SGID
   binaries, world-writable paths. Verify against `docker-compose.yml`:
   - `/workspace` is a directory bind of `~/repo/<PROFILE>` (host), rw.
   - `/root/.claude` is a directory bind of
     `~/.ai-sandbox/profiles/<PROFILE>/claude-home`, rw.
   - `/root/.claude.json` is a **single-file bind** of
     `~/.ai-sandbox/profiles/<PROFILE>/claude.json`. Under rootless
     Docker on ext4 this works without the virtiofs UID-remap quirks
     macolima had, so 600 vs 644 is not load-bearing here — but
     `init-profile-state.sh` seeds it as `{}` on first up. Confirm
     valid JSON and that it's writable by in-container root.
   - `/root/.claude/.credentials.json` (if present) should be **mode
     600**. Lives inside a directory bind so this is straightforward.
   - `/root/.config` is a directory bind of
     `~/.ai-sandbox/profiles/<PROFILE>/config`, holds `gh/`,
     `glab-cli/`, and `git/config`.
   - `~/.gitconfig` is **NOT** bind-mounted. `GIT_CONFIG_GLOBAL`
     should be set to `/root/.config/git/config` in env. Verify
     `init-profile-state.sh` has scrubbed any VS Code-injected
     `credential.helper` from that file (Finding B remediation).
   - `/root/.cache` is a directory bind for npm/uv/pip caches.
   - `~/.vscode-server` (if VS Code is attached) is a directory bind
     under `~/.ai-sandbox/profiles/<PROFILE>/` — **NOT a named volume**
     (this differs from macolima, which needed a named volume to dodge
     virtiofs rename EBUSY; WSL2 ext4 doesn't have that issue).
   - tmpfs mounts: `/tmp` (1g), `/run` (64m), `/root/.npm-global`
     (512m), `/root/.local` (256m) — all must carry
     `noexec,nosuid,nodev`. Owners are in-container root, which is
     correct under userns=host.
   - `/usr/lib/wsl` is a read-only bind from the WSL host (WSL2 GPU
     userland libs). Expected.
   - `/dev/dxg` device should be present (WSL2 GPU).
   - Base image: confirm the running image digest matches the
     `FROM nvidia/cuda:12.6.3-base-ubuntu24.04@sha256:...` pin in
     Dockerfile (drift = local retag or unpinned rebuild).
5. /proc and /sys exposure: masked paths, readability of `/proc/kcore`,
   `/proc/sys/kernel/*`, `/sys/kernel/*`. Note that under rootless
   Docker some `/proc/sys` paths are more restricted than rootful by
   default.
6. PID namespace & process visibility: PID of init as seen from the
   container (should be 1 = `sleep infinity`), total visible processes,
   whether any host/VM processes leak in. Squid in the sibling
   container should NOT be visible.
7. Devices: `/dev` contents; only `/dev/dxg` should be passed through
   from the host. Flag any other host device.
8. Cgroups: should be v2 under modern WSL2. Visible limits should
   reflect `pids_limit: 512`, `mem_limit: 8g`, `cpus: 4`. Writable
   controllers — rootless Docker may leave the unified hierarchy
   read-only from in-container; verify.
9. Network & egress: interfaces, routes, whether host netns is shared
   (must NOT be), reachable hosts on the container's bridge
   (`sandbox-internal` — `internal: true`). Then confirm egress
   control:
   (a) a domain on `proxy/allowed_domains.txt` succeeds via proxy
       (use `https://api.anthropic.com` as the reliable probe — the
       agent's `HTTPS_PROXY` env points to `egress-proxy:3128`),
   (b) a domain NOT on the list is refused by the proxy
       (e.g. `https://example.com` should be denied),
   (c) **direct egress bypassing the proxy fails** — attempt a raw
       TCP connect (`/dev/tcp/1.1.1.1/443` from bash) without
       `HTTPS_PROXY` set. Expect network unreachable / no route
       because `sandbox-internal` is `internal: true`. Do NOT test
       (c) through a proxy-aware curl — that produces a false OK.
   (d) Enumerate `proxy/allowed_domains.txt` and flag any broad
       wildcards (e.g. `*.microsoft.com`) as **WEAK**. Note the
       PROJECT-PERSISTENT vs PLANNING-MODE section split: only
       PROJECT-PERSISTENT entries are live by default; PLANNING-MODE
       sections are commented out and only enabled transiently by
       `scripts/with-egress.sh`. Active allowlist = uncommented lines
       only.
   (e) `gh`/`glab` OAuth **browser** flow is intentionally broken
       (no published ports, `sandbox-internal` is internal). Device-
       code token flow is the documented path — do NOT report this
       as drift.
   (f) Forwarded ports declared in compose: 8080, 8501, 8188. Confirm
       these are bound to `127.0.0.1` on the WSL host side, not
       `0.0.0.0`. Flag any `0.0.0.0` binding.
10. WSL2 boundary: identify signals that this is WSL2 (kernel string
    contains `microsoft-standard-WSL2`, presence of `/dev/dxg`,
    `/usr/lib/wsl` bind, `/run/user/1000/docker.sock` rootless socket
    via `DOCKER_HOST` env). Note what — if anything — is visible
    about the host Windows side or the WSL utility VM from inside.
    Do not attempt to cross the WSL VM boundary.
11. Kernel: `uname -a`. CVE enumeration is out of scope from inside
    (no internet); host-side `scripts/trivy-scan.sh` covers image CVEs
    separately. The kernel belongs to the WSL utility VM, not this
    container.
12. Claude Code harness config: `/root/.claude/settings.json` is
    expected to contain `"sandbox": {"enabled": false}` (Claude Code's
    internal bwrap sandbox can't run here — it requires unprivileged
    user namespaces, which are correctly blocked by seccomp §3, and
    bwrap is not installed anyway). Presence of this setting is **OK**,
    not drift. Also expected: a `permissions.deny` list covering
    `curl/wget/ssh/scp/socat/nc/telnet`, `git push/clone/fetch`,
    `pip install`, `uv add`, secrets reads, and a `hooks.PreToolUse`
    entry pointing at `/usr/local/lib/deny-destructive.sh` (baked into
    image). Flag if any of those are missing or weakened. Cross-check
    against the template in `config/claude-settings.json`.
13. Deny-destructive hook: verify `/usr/local/lib/deny-destructive.sh`
    exists, is executable, owned by root, and matches the staged
    `config/hooks/deny-destructive.sh`. The hook script's integrity
    relies on `permissions.deny` entries blocking Edit/Bash tampering
    with its path — there is no kernel-enforced write-protect under
    rootless (in-container root *can* overwrite it). Confirm the
    relevant deny rules are present in `settings.json` (`hook-tamper`
    rules).
14. Secrets hygiene:
    - Env vars, mounted config, anything credential-like in
      `/root/.claude/`, `/root/.config/gh/`, `/root/.config/glab-cli/`.
      Redact values in the report.
    - **SSH agent forwarding**: `env | grep SSH_AUTH_SOCK` and
      `ls -la /tmp/ssh-* /tmp/vscode-ssh-* 2>/dev/null`. The compose
      file does not forward the host SSH agent, but VS Code Dev
      Containers can inject `SSH_AUTH_SOCK` per user setting
      (`remote.SSH.enableAgentForwarding`). Belt-and-braces: the
      Dockerfile purges `openssh-client`, so even with a forwarded
      socket the agent has no ssh client. Presence of either still
      = **WEAK** with the socket path so I can disable the VS Code
      setting (Finding A).
    - **GitConfig leakage** (Finding B): confirm no
      `credential.helper` line in `/root/.config/git/config`.
      `init-profile-state.sh` scrubs this on every `up`, but
      VS Code's `dev.containers.copyGitConfig` can re-inject.
      Presence = WEAK.

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
   expected files; if anything is missing, tell me to re-stage with
   `scripts/profile.sh <PROFILE> audit --stage-only`.
2. Run `bash /workspace/temp_audit_package/scripts/verify-sandbox.sh`
   and summarize which invariants it already covers. Unlike the
   macolima ancestor of this prompt, there are no "known stale"
   asserts here — treat any FAIL as real drift.
3. Optionally inspect the latest Tier-2 JSON at
   `/root/.claude/audits/` (produced by `scripts/profile.sh <p> audit`
   host-side). If you'd rather I re-run it before you start, say so.
4. Summarize your plan in one paragraph: what you'll check beyond
   verify-sandbox.sh, what local probes you intend to run in `/tmp`,
   and anything you want me to approve up front.
5. Wait for my go-ahead.
