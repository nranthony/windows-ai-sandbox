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

---

## uv resolution quarantine (`exclude-newer`) — per project, not image-wide

The slopsquat quarantine is set globally for npm (`min-release-age=7`, Dockerfile)
and pnpm (`minimum-release-age=10080`, per-profile rc). **uv's equivalent is
deliberately NOT set image-wide.**

`exclude-newer` takes a timestamp, not a duration — it pins resolution to "as of
date X" rather than "nothing younger than N days". Setting one image-wide would
freeze every project in every profile at a fixed date and quietly go stale, which
on a CUDA/ML image is a footgun rather than a control. It belongs in the project
that wants it, committed next to the code it constrains:

```toml
[tool.uv]
exclude-newer = "2026-07-01T00:00:00Z"
```

For the sandbox, the control that actually covers uv is the egress boundary: the
`[pypi]` block in `proxy/allowed_domains.txt` is commented by default, so uv
cannot resolve at all outside a `scripts/with-egress.sh` window. That gates
*when* resolution may happen; `exclude-newer` gates *what* it may resolve to.
Use it on any project where a reproducible resolution date matters.

See [`docs/_archive/dependency-guardrails-plan.md`](_archive/dependency-guardrails-plan.md) T11.
