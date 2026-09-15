# ADR-0013 — The environment names the venv, not the repo

- **Status:** Accepted (2026-09-15; decided on the sibling 2026-09-11)
- **Deciders:** nranthony + agent
- **Work item:** `work/0030-venv-and-notice-replay/` (replaying `macolima@work/0008`)
- **Shared number:** macolima's ADR-0013 is the same decision; the two repos
  number shared decisions alike (`docs/index.md`).

## Context

`/workspace` is the host's checkout, bind-mounted. So every Python repo is seen
by two environments at once, the host and the profile's container, and both
default to `<repo>/.venv`. A venv is not portable: `.venv/bin/python` is a
symlink to one interpreter on one machine, and its console scripts carry an
absolute shebang.

The failure is worse than "one side is broken". **uv, finding a project
environment whose interpreter it cannot use, deletes and recreates it.** On the
Mac the collision is loud (a macOS venv cannot run in the container at all). On
this substrate it is **quiet**: the image and the host are both Ubuntu 24.04
with `/usr/bin/python3` 3.12.3 at the same path, so a `.venv` built on either
side often *runs* on the other, and nothing is noticed until one side switches
interpreter (the container's `/opt/uv` 3.13, which the host lacks) and uv
silently rebuilds the venv for the other. Before that, a container `uv sync`
may instead sync *into* the host's venv as it stands: container-installed
packages, and console scripts whose `/home/…` shebangs do not resolve inside
the container.

Repos had worked around it one at a time, and inconsistently: a `.venv-linux`
built by hand in the container, scripts hard-coding `.venv-linux/bin/python`, a
`CLAUDE.md` telling agents to `export UV_PROJECT_ENVIRONMENT=.venv-linux`, a
justfile choosing a venv by `os()`. **Selecting by OS is wrong in principle
here:** this sandbox's host and container are both Linux and both pick the
same name.

## Decision

**The environment names the venv; a repo never chooses it.**

| Where | `UV_PROJECT_ENVIRONMENT` | Venv |
|---|---|---|
| Any sandbox container: this repo (Docker on WSL2 / bare Linux, x86_64) and the sibling (Colima, arm64) | `.venv-sandbox`, from compose `environment:` | `<repo>/.venv-sandbox` |
| Any host: WSL, bare Linux, macOS, CI runners | **unset** | `<repo>/.venv` (uv's default) |

uv reads the variable on every `uv run` / `uv sync` / `uv venv`, and a
**relative** value resolves against the project root, not the CWD (measured on
the sibling with uv 0.12.9, from a subdirectory and via `uv run --project`).
So one value serves every repo, and the container's uv never sees the host's
`.venv`.

Repos follow from that:
- they run things through `uv run …`;
- where a path is unavoidable, they derive it from `UV_PROJECT_ENVIRONMENT`
  with `.venv` as the fallback;
- they never select a venv by OS;
- they gitignore `.venv*/`;
- they pin a tracked `.python-version`, to a minor every environment has. This
  image bakes 3.12 and 3.13, the same set as the sibling; unpinned, uv takes
  the newest.

That repo-side half is the `agentic-conventions` rule, its **ADR-0017** "The
environment names the venv", shipped in **myconv 0.9.0** and vendored here as
`myconv` through the channel (ADR-0014).

**The one exception:** two *hosts* sharing one checkout — Windows-native
Python and WSL both working under `/mnt/c`, or a folder synced between
machines. Both are hosts, so both pick `.venv`, and that pair alone needs
per-host names set in each host's shell profile. The 2026-09-15 scan of this
machine found no `.venv` under `/mnt/c`; none is known.

## Consequences

- `docker-compose.yml` sets the variable in `claude-agent.environment`,
  **compose rather than Dockerfile `ENV`** even though this repo keeps
  `UV_LINK_MODE` in the Dockerfile: the variable only matters where the bind
  mounts are, and a change must be a recreate, not a rebuild. (`UV_LINK_MODE`
  stays where it is: it is the exception, not the pattern.)
  `verify-sandbox.sh` fails on unset, absolute, or any other name.
- **The deletion hook's disposable exception is `.venv-sandbox`, and no longer
  `.venv`.** From inside the container a plain `.venv` is the host's venv, so
  deleting in it now reaches the prompt. The name is matched exactly, because
  targets are wrapped in slashes and `*/.venv*/*` would also pass a file named
  `.venvrc`. The `/root/.cache` carve-out is unchanged.
- The sandbox notice tells agents which venv is theirs and not to set the
  variable themselves (ADR-0015 carries the text).
- **Rollout order: switch first, repos after.** Merging the compose line is the
  switch for every profile at its next recreate, and until a profile has
  switched, a container `uv run` is itself the destructive command. So all
  profiles are recreated in one sitting, and only then are the migrated repos
  pulled (their edits assume the variable) and built.
- **Only uv's project commands read the variable** (`run`, `sync`, `venv`).
  `uv pip` ignores it and uses `VIRTUAL_ENV` or a `.venv` in the current
  directory, which in the container is the host's. So a `uv pip` call names
  its target: `--python .venv-sandbox`. The agent is denied `uv pip install`
  regardless; this is for humans in a container shell and for read-only
  `uv pip list` / `show`.
- A venv is rebuilt, never renamed: console-script shebangs are absolute.
- **Classify by shebang, not by `pyvenv.cfg`.** On a Linux host `home` is
  `/usr/bin` on both sides. Console scripts are not: a container-built venv's
  start `#!/workspace/<repo>/…`, a host-built one's `#!/home/<user>/repo/…`.
  `scripts/workspace-scan.py` reads the shebang and reports UNKNOWN rather than
  guessing when there is none.
- Retiring the old venvs (`.venv-linux`, container-built leftovers in `.venv`
  slots) is a human deletion after a soak. Rootless Docker is what makes that
  a host-side `rm`: container root maps to the host user, so the files are
  host-owned. Under rootful Docker they would need `sudo`.
- The uv cache here is a per-profile **bind mount** (`profiles/<p>/cache`),
  not a named volume, so every profile's first `.venv-sandbox` build is a cold
  cache and an egress window; re-comment the planning-mode domains after.
- VS Code on the Windows host points its default interpreter at the baseline
  `/root/.venv`, which is not a project venv. Whether repos in the container
  should get `${workspaceFolder}/.venv-sandbox/bin/python` instead is a
  Windows user-settings decision, not a repo file (work/0030 R2).
- `scripts/workspace-scan.py` checks every profile's repos host-side;
  `--fail-on HARDCODED-VENV-LINUX,OS-VENV-SELECT` is the "migration finished"
  check.

## Rejected alternatives

- **Per-OS names** (`.venv-linux` in the container). A Linux host and a Linux
  container collide, which was live here.
- **Per-host names on every host** (`.venv-wsl`, `.venv-mac`, …). Every host's
  shell profile would need the variable, and every existing host venv would be
  rebuilt, to solve a collision only the container side has.
- **An architecture suffix** (`.venv-sandbox-x86_64`). Each sandbox shares a
  checkout only with its own host.
- **`UV_PYTHON` in the image.** It is `--python`, so it overrides every repo's
  `.python-version`.
- **Dockerfile `ENV`.** Every change would be a rebuild, and the build has no
  bind mounts for the variable to matter in.
- **"Repos first", with fallback wording in repo docs.** Transitional text in
  repos for a window that switching first removes.
- **A per-profile opt-in variable.** A permanent mechanism for a one-time
  ordering problem.
