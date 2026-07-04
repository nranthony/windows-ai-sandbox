# Sandbox design notes

Background on architectural choices that look surprising in the code but exist for a specific reason. Editing-time invariants live in `AGENTS.md` / `ARCHITECTURE.md`; this is the "why."

## Container runs as root — by design

Under rootless Docker with `userns=host`, container UID 0 maps to host UID 1000 (NOT root). Switching to a non-root user inside the container would remap to host UID 100999 (nobody) and break workspace bind-mount writes.

## Rootfs is NOT read-only

`read_only: true` was tried and removed on the agent container. It breaks VS Code Dev Containers' `/etc/environment` patching with no security gain (rootless userns + `cap_drop: ALL` already blocks system-dir writes from reaching the host). Stays on `egress-proxy` because Squid doesn't need rootfs writes.

## Claude Code's bwrap sandbox is disabled; the container is the boundary

Claude Code's `Bash` tool wraps every command in `bwrap` (bubblewrap). bwrap implements isolation by calling `unshare(CLONE_NEWUSER)`, which our seccomp filter **correctly blocks**. Result: every Bash call would fail with `bwrap: No permissions to create new namespace`. Two sandboxes with incompatible mechanisms; the container is the stronger outer boundary.

Three load-bearing consequences:

1. **`sandbox.enabled: false`** in `~/.claude/settings.json`.
2. **`bubblewrap`, `socat`, and `openssh-client` are NOT installed** in the Dockerfile. Each was either dead weight or an exfil path:
   - `bubblewrap` only supported the in-process sandbox (now disabled).
   - `socat` was a raw-TCP exfil channel bypassing the HTTP-only Squid egress.
   - `openssh-client` (`ssh`/`scp`/`sftp`/`ssh-agent`/...) is the tool surface that weaponizes VS Code's `SSH_AUTH_SOCK` forwarding if it ever reappears. gh/glab use HTTPS tokens; git remotes are HTTPS; agent-mode denies `git push|clone|fetch`.
3. **`sandbox_templates/claude/claude-settings.json`** is the per-profile settings template. `ensure_state()` copies it into `profiles/<p>/claude-home/settings.json` on first `up` (only if absent — existing profiles keep customizations).

Do **not** "re-harden" by re-enabling `sandbox.enabled` or re-adding `bubblewrap`/`socat`/`openssh-client`.

## Per-profile Claude Code skills are seeded from `sandbox_templates/skills/`

Skills live at `sandbox_templates/skills/<name>/SKILL.md` and are seeded into each profile's `claude-home/skills/<name>/` by `ensure_state()` on first `up` — copy only if absent, so user customisations survive subsequent `up`s. To force-refresh from template: `scripts/profile.sh <p> reset-skills`.

## Commit identity: `git config` is denied — seed `user.*` host-side

The agent's deny list blocks `git config` because that subcommand can rewrite `credential.helper` to a host-reaching shim between `ensure_state()` scrub passes. The matcher is keyed on the command prefix, so benign subcommands (`git config user.name "…"`) are caught in the same net.

Two legitimate paths to attribute commits correctly:

1. **Persistent (preferred):** set `GIT_USER_NAME` / `GIT_USER_EMAIL` env vars in your host shell rc. `ensure_state()` auto-seeds `[user] name=…  email=…` into the profile's `config/git/config` on first `up` if the `[user]` section is missing.
2. **Per-commit env-var fallback:** `GIT_AUTHOR_NAME=… GIT_AUTHOR_EMAIL=… GIT_COMMITTER_NAME=… GIT_COMMITTER_EMAIL=… git commit …`. Sets identity on the single commit object only; no config file write.

## gh/glab and the proxy

`gh` and `glab` are installed at build time (direct internet via host daemon). At runtime they go through Squid. `gh auth login` uses `github.com` + `api.github.com`; `glab` uses `gitlab.com`.

**OAuth browser flow is structurally broken** — both default to a callback on `http://localhost:<port>` inside the container, which the host browser can't reach because `sandbox-internal` is `internal: true` with no published ports (by design). Token flow only.

## VS Code re-attach after container recreate

`docker compose up -d --force-recreate` changes the container ID. VS Code Dev Containers caches attachment by ID. After recreate: `Remote: Close Remote Connection` → re-attach, or reload window, or relaunch VS Code.
