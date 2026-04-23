# Sandbox hardening package — post-audit remediations

**Audience:** a Claude instance on Windows + WSL2 + rootless Docker + VS Code Dev Containers, helping a user harden a similar Claude-Code-in-a-container setup.

**Source environment:** macOS + Colima VM + rootful Docker + VS Code Dev Containers. Audit of a single profile (`therapod`) against a hardened reference (`macolima`). Auditor ran inside the container, read-only, against a pre-staged config bundle. Full report at `/Volumes/DataDrive/repo/therapod/sandbox-audit-therapod-2026-04-22.md` (not included here — this doc is the actionable distillation).

**Date:** 2026-04-23.

---

## 1. What the audit was checking

The reference sandbox posture (`CLAUDE.md` in the macolima repo) enforces these invariants at runtime:

- Agent UID 1000, non-root, `cap_drop: ALL`, `no_new_privs=1`, seccomp mode 2 with a curated allowlist.
- `clone3` returns `ENOSYS` (not `EPERM`) so glibc's threading fallback works; `unshare(CLONE_NEWUSER)` blocked.
- Agent container on an `internal: true` Docker network — only reachable host is a Squid egress proxy with a domain allowlist.
- Base image digest-pinned.
- Persistent state scoped to per-profile bind mounts; `/tmp` + `/home/agent/.local` + `/home/agent/.npm-global` tmpfs with noexec/nosuid/nodev.
- Claude Code's in-process `bwrap` sandbox disabled (it requires unprivileged user namespaces, which seccomp correctly blocks); the container is the boundary.
- `bubblewrap` and `socat` deliberately not installed (dead weight + raw-TCP exfil channel respectively).

All of those held at runtime. The audit did not find a container-escape or network-bypass. It found **IDE integration leakage** — things VS Code Dev Containers injects into the container that the network model doesn't account for.

---

## 2. Findings and fixes

### Finding A — VS Code forwards host SSH agent into the container

**Observed:** `SSH_AUTH_SOCK=/tmp/vscode-ssh-auth-*.sock` was set inside the container. Any process as the agent user could `ssh` to any host whose keys were in the user's host `ssh-agent`.

**Why it matters:** The egress proxy is HTTP/S only (Squid). The firewall blocks direct TCP to external hosts. Neither control sees SSH traffic routed through the forwarded unix socket — the socket itself *is* the bypass. The container's network identity is sandboxed; its SSH identity is the host user's.

**Fix — host-side VS Code setting:**
```json
"remote.SSH.enableAgentForwarding": false
```

### Finding B — VS Code copies host `~/.gitconfig` into container rootfs

**Observed:** `/home/agent/.gitconfig` existed as a regular file on the overlay rootfs (not a bind mount), containing the host user's git identity and macOS-specific credential helpers (`osxkeychain`, `gcm-core`). Git was not using it (an env var `GIT_CONFIG_GLOBAL` pointed elsewhere), but it was readable.

**Why it matters:** Identity leak + foot-gun — anyone unsetting or shadowing `GIT_CONFIG_GLOBAL` would silently fall back to host identity. Also pollutes the container with paths to binaries that don't exist inside it.

**Fix — host-side VS Code setting:**
```json
"dev.containers.copyGitConfig": false
```

### Finding C — VS Code injects a git credential helper that calls home

**Observed:** `.config/git/config` inside the container contained:
```
[credential]
  helper = "!f() { /home/agent/.vscode-server/bin/<hash>/node /tmp/vscode-remote-containers-*.js git-credential-helper $*; }; f"
```
Plus env: `GIT_ASKPASS`, `VSCODE_GIT_IPC_HANDLE`, `VSCODE_GIT_ASKPASS_MAIN`.

**Why it matters:** Any `git push`/`clone`/`fetch` inside the container invokes the helper, which talks over a unix socket back to the VS Code process on the host, which asks the host credential manager and returns the secret. The container never sees the credential at rest, but during the operation it has full access to whatever host creds exist for that remote — completely bypassing the proxy allowlist.

**Fix — two layers:**

*Layer 1 (host):* `dev.containers.copyGitConfig: false` (from Finding B) should prevent the initial injection on attach.

*Layer 2 (defensive, in our setup script):* strip any `credential.helper` from the profile's git config on every `up`, so the setting can't survive even if the host setting gets reverted or VS Code re-injects on attach. See §3 (profile.sh change) for the exact code.

### Finding D — Orphaned UID-0 `/bin/sh` with PPid=0

**Observed:** `ps` inside the container showed a `/bin/sh` process running as root, orphaned (PPid=0), spawned during VS Code attach. Capabilities all zero, `NoNewPrivs=1`, `Seccomp=2` — inherited the same sandbox posture as everything else, so it couldn't escape or escalate.

**Why it matters:** It's still UID 0, so it can write to any root-owned path on the writable overlay rootfs (`/etc`, `/usr`). That state is ephemeral (wiped on recreate), so blast radius is bounded to this container's lifetime — but it's drift from the intended "agent-only" posture, and it indicates a VS Code hook running as root that you didn't ask for.

**Fix — two parts:**

*Part 1 (immediate):* kill the shell from the host:
```bash
docker exec -u 0 claude-agent-<profile> kill <PID>
```

*Part 2 (prevent recurrence):* drop a `devcontainer.json` in the **workspace repo** (not the sandbox repo) pinning `remoteUser`, `containerUser`, and `updateRemoteUserUID: false`. See §5 for the template.

### Finding E — Copilot IDE state (`~/.copilot/ide/`)

**Observed:** Directory existed with mode 700.

**Action:** Inspected contents — single `.lock` file, 300 bytes, mode 600. No credentials. Harmless, no action.

### Finding F — Base image digest verification

**Observed:** Dockerfile pins `FROM ubuntu:24.04@sha256:c4a8d5503dfb…c7b`. Not verifiable from inside the container.

**Action:** Verified from host: `docker image inspect ubuntu:24.04 --format '{{json .RepoDigests}}'` returns the same digest. Match confirmed.

### Finding G — `noexec` flag drift on tmpfs

**Observed:** Compose file declared `/home/agent/.npm-global` and `/home/agent/.local` as tmpfs with `nosuid,nodev,uid=1000,gid=1000,mode=0755` but no explicit `noexec`. Runtime showed them noexec anyway (Docker default), but explicit is better than implicit.

**Fix:** Added `noexec` to the tmpfs mount flags in compose. See §3.

---

## 3. Exact changes applied to the macolima repo

### `docker-compose.yml` — agent tmpfs entries

```diff
     tmpfs:
       - /tmp:size=1g,noexec,nosuid,nodev
       - /run:size=64m,noexec,nosuid,nodev
-      - /home/agent/.npm-global:size=512m,nosuid,nodev,uid=1000,gid=1000,mode=0755
-      - /home/agent/.local:size=256m,nosuid,nodev,uid=1000,gid=1000,mode=0755
+      - /home/agent/.npm-global:size=512m,noexec,nosuid,nodev,uid=1000,gid=1000,mode=0755
+      - /home/agent/.local:size=256m,noexec,nosuid,nodev,uid=1000,gid=1000,mode=0755
```

### `scripts/profile.sh` — defensive credential-helper scrub in `ensure_state()`

```bash
# Defensive scrub: VS Code Dev Containers can inject a host-routed git
# credential helper into .config/git/config (via VSCODE_GIT_IPC_HANDLE +
# a node shim in .vscode-server). That helper forwards git auth to the
# host's credential manager, bypassing the sandbox's network identity.
# Strip any credential.helper on every `up` so the setting can't survive
# across recreates even if `dev.containers.copyGitConfig` re-enables.
if [[ -f "$p/config/git/config" ]]; then
  git config --file "$p/config/git/config" --unset-all credential.helper 2>/dev/null || true
fi
```
Added to the end of `ensure_state()` before the closing `}`. Runs on every `profile.sh <p> up`.

### Host VS Code `settings.json`

```jsonc
// Prevents VS Code from leaking host credentials into sandboxed containers
"dev.containers.copyGitConfig": false,
"remote.SSH.enableAgentForwarding": false,
```

---

## 4. Translating to WSL2 + rootless Docker + devcontainers

The VS Code-layer findings (A/B/C/D) are **platform-independent** — they're VS Code Dev Containers behavior, not a macOS or Colima quirk. Apply the same fixes verbatim. The settings key names are identical on Windows VS Code.

### What changes under rootless Docker

Rootless Docker runs the Docker daemon as a non-root user on the host and uses `newuidmap`/`newgidmap` to give the daemon a subuid/subgid range (usually `100000-165535`). This shifts the threat model in a few relevant ways:

1. **Container UID 0 maps to an unprivileged host UID** (e.g. host UID 100000), not host root. The orphan-root-shell finding (D) is materially less scary — worst case it can scribble on an ephemeral overlay, and even that runs as a host-subuid user. Still worth fixing because drift is drift, but the blast radius is smaller than on rootful Docker.
2. **seccomp still applies identically.** The filter is enforced by the kernel regardless of daemon ownership. All the syscall-level invariants (`clone3`→ENOSYS, `unshare(CLONE_NEWUSER)` blocked, etc.) hold.
3. **`cap_drop: ALL` still applies** — but the capabilities available to the daemon's user namespace are already reduced, so some of the caps being dropped were never held anyway. Doesn't hurt to drop them explicitly.
4. **User namespaces are already in use** for the daemon's own remapping. The seccomp filter blocking `unshare(CLONE_NEWUSER)` means the container *can't create nested* user namespaces, which is what you want.

### What changes under WSL2

1. **Filesystem:** containers' overlay lives on the WSL2 distro's ext4 (fast, POSIX-compliant). Bind-mounting paths from `/mnt/c/...` (Windows NTFS via 9p) is slow and has UID/permission quirks analogous to virtiofs on macOS — **prefer bind mounts from the Linux filesystem** (`/home/<user>/...`) over Windows mounts for the agent's state dir, workspace, and cache. The `.vscode-server` named-volume workaround we use isn't strictly necessary under WSL (ext4 handles utime fine) but doesn't hurt and gives you identical semantics to macOS.
2. **Network:** WSL2 containers reach out through the WSL2 VM's NAT. Create the agent's network as `internal: true` the same way — Docker's network driver behaves identically. The egress proxy pattern transfers unchanged.
3. **`/Volumes` equivalent:** n/a. Use `/home/<user>/sandbox-profiles/` or similar on the Linux side.
4. **Colima equivalent:** there's no extra VM layer — WSL2 *is* the VM. Skip any Colima-specific steps.

### What to add to their compose file

If they're starting from scratch rather than translating an existing compose file, the non-negotiables are:

```yaml
services:
  agent:
    image: <their-image>
    user: "1000:1000"          # or whatever their non-root UID is
    cap_drop: [ALL]
    security_opt:
      - no-new-privileges:true
      - seccomp=./seccomp.json
    tmpfs:
      - /tmp:size=1g,noexec,nosuid,nodev
      - /home/agent/.npm-global:size=512m,noexec,nosuid,nodev,uid=1000,gid=1000,mode=0755
      - /home/agent/.local:size=256m,noexec,nosuid,nodev,uid=1000,gid=1000,mode=0755
    pids_limit: 512
    mem_limit: 8g
    networks: [sandbox-internal]
    environment:
      - HTTP_PROXY=http://egress-proxy:3128
      - HTTPS_PROXY=http://egress-proxy:3128
      - NO_PROXY=localhost,127.0.0.1,egress-proxy
      - GIT_CONFIG_GLOBAL=/home/agent/.config/git/config
    # Required for Dev Containers attach to not drop to an inferior shell:
    command: ["sleep", "infinity"]
  egress-proxy:
    image: ubuntu/squid:latest
    cap_drop: [ALL]
    cap_add: [SETUID, SETGID]   # Squid needs these to drop privs at startup
    networks: [sandbox-internal, sandbox-external]

networks:
  sandbox-internal:
    driver: bridge
    internal: true              # LOAD-BEARING — this is the egress cutoff
  sandbox-external:
    driver: bridge
```

The `internal: true` on `sandbox-internal` is what makes the whole model work. Without it, the proxy is a suggestion, not an enforcement point.

---

## 5. The devcontainer.json to add in the **workspace** repo (not the sandbox repo)

Drop this at `<workspace-repo>/.devcontainer/devcontainer.json`:

```jsonc
{
  "name": "<profile-name>",
  "image": "<image-name>:latest",
  "workspaceFolder": "/workspace",
  "remoteUser": "agent",
  "containerUser": "agent",
  "overrideCommand": false,
  "updateRemoteUserUID": false
}
```

Field-by-field:

- **`remoteUser`**: the UID VS Code's user-facing processes (terminal, tasks, extension host) run as. Without this, VS Code picks a default that may be root.
- **`containerUser`**: the UID the container is treated as running as. Should match the compose `user:` directive.
- **`overrideCommand: false`**: do NOT replace the compose `command: ["sleep", "infinity"]`. Default is `true`, which replaces it with a VS Code-specific command that runs as root.
- **`updateRemoteUserUID: false`**: the critical one. By default, on attach VS Code will try to `usermod` the in-container user to match the **host** UID, because it assumes you want file ownership to line up. That `usermod` runs as root — which is what spawned the orphan shell in Finding D. Under rootful Docker it also fails silently because `sudo` isn't installed. Under rootless Docker the semantics are different (host UID is already remapped), so this setting is even more clearly wrong by default. Setting it `false` tells VS Code "the UIDs inside are intentional, leave them alone."

**Why this goes in the workspace repo, not the sandbox repo:** the sandbox repo defines the image and compose stack, potentially shared across many workspaces. The `devcontainer.json` is attach-time config — it describes how VS Code should enter *this specific workspace*. Putting it in the sandbox repo would impose the same attach semantics on every workspace that uses the image.

**Alternative if you don't want to commit it:** add it to `.git/info/exclude` in the workspace repo. VS Code reads it from the working tree either way.

---

## 6. Verification after applying

Run these from inside the container after the next `up --force-recreate` and VS Code re-attach:

```bash
# A — SSH agent forwarding gone
echo "SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-<unset>}"
ls /tmp/vscode-ssh-auth-* 2>/dev/null && echo FAIL || echo OK

# B — host gitconfig not copied
test -f /home/agent/.gitconfig && echo FAIL || echo OK

# C — no credential helper
grep -E '^\s*helper\s*=' /home/agent/.config/git/config && echo FAIL || echo OK

# D — no UID-0 processes except PID 1
ps -eo pid,user,comm | awk 'NR>1 && $2=="root" && $1!=1 {n++} END{exit (n?1:0)}' && echo OK || echo FAIL

# Core invariants (should still pass)
grep '^Seccomp:'    /proc/self/status   # → 2
grep '^CapEff:'     /proc/self/status   # → 0000000000000000
grep '^NoNewPrivs:' /proc/self/status   # → 1
id -u                                   # → 1000
awk '$2=="/"{print $4}' /proc/mounts    # check for ro vs rw (rw is intended)
```

Any FAIL indicates the corresponding fix didn't stick — most likely the host VS Code setting wasn't saved or the container wasn't recreated.

---

## 7. What is explicitly NOT to do

- **Don't re-enable Claude Code's `bwrap` sandbox.** It needs unprivileged user namespaces, which seccomp blocks. The container is the boundary; the in-process sandbox is redundant at best and a confusion vector at worst.
- **Don't install `bubblewrap` or `socat` in the image.** The first was only for the disabled in-process sandbox. The second was a raw-TCP exfil channel that bypasses Squid's HTTP-only egress.
- **Don't widen the proxy allowlist to include `host.docker.internal` or equivalents** so the container can reach host services. That's the exact coupling the sandbox exists to prevent. If the agent needs real data, dump it into a sibling container on `sandbox-internal`.
- **Don't bind-mount `~/.gitconfig` as a single file** to "fix" Finding B. `git config --global` writes via `rename()` atomically and atomic rename across a single-file bind mount returns `EBUSY` on virtiofs (and has its own quirks on WSL 9p). Use `GIT_CONFIG_GLOBAL` pointing to a file inside a **directory** bind mount instead.
- **Don't set `read_only: true` on the agent container.** It breaks VS Code Dev Containers' environment setup (specifically writes to `/etc/environment`). The security gain is zero given non-root + `cap_drop: ALL` already blocks system-dir writes.
