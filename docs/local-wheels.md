# Per-profile `dist/` for local wheels

Convention: `~/repo/<profile>/dist/` holds local `.whl` files (and other build artifacts) that should be installed into the profile's in-container venv but aren't on PyPI. Visible inside the container at `/workspace/dist/` because `/workspace` is the bind mount of the profile's repo dir. Use this for sibling-repo libraries instead of widening the proxy to a private index.

## Workflow

```bash
# host (WSL): build the wheel from its source repo
cd ~/repo/<other-repo> && uv build
cp dist/<lib>-*.whl ~/repo/<profile>/dist/

# container: install into the project venv
cd /workspace/<project> && source .venv/bin/activate
uv pip install /workspace/dist/<lib>-*.whl
```

The directory is per-profile and lives on the WSL ext4 filesystem — survives container recreate. `dist/` matches the standard Python `.gitignore` entry, so wheels won't get committed by accident if a workspace is itself a git repo.

## Cross-environment `pyproject.toml`

`uv pip install <wheel>` works once but a subsequent `uv sync` will rip it back out unless `pyproject.toml` declares the source. A host-absolute path in `[tool.uv.sources]` blows up inside the container — only `~/repo/<profile>` is mounted (as `/workspace`), so cross-profile source paths aren't reachable. Fix is a platform-conditional source:

```toml
[tool.uv.sources]
<lib> = [
    { path = "/home/<user>/repo/<other-repo>",
      editable = true,
      marker = "platform_system != 'Docker'" },
    { path = "/workspace/dist/<lib>-0.1.0-py3-none-any.whl",
      marker = "platform_system == 'Linux'" },
]
```

Bump the wheel filename in lockstep with the upstream `version` field.
