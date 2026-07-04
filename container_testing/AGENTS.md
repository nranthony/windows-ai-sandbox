# CUDA Container Testing Workspace

Validation workspace for GPU passthrough and CUDA availability inside the
sandbox image. A uv project (`torch`/`torchvision` from the cu126 wheel
index) plus `cuda_test.ipynb`.

## Workflow

```bash
# From the host, against a running profile whose /workspace holds this repo:
scripts/profile.sh <profile> exec bash -lc '
  cd /workspace/windows-ai-sandbox/container_testing && uv sync && \
  uv run python -c "import torch; print(torch.cuda.is_available())"
'
```

Use `uv sync` / `uv run` — never bare pip. The cu126 wheels are large; if the
install is blocked by the egress allowlist, widen temporarily with
`scripts/with-egress.sh <profile> --with pypi,pytorch -- '<cmd>'`.

## Expected results per substrate

- **WSL2 + GPU** (wsl-gpu overlay active): `torch.cuda.is_available()` → `True`.
  `False` there means overlay drift — check `/dev/dxg` and `/usr/lib/wsl` in
  the container, then `scripts/profile.sh <profile> verify`.
- **Bare-Linux host (no GPU)**: `False` is the CORRECT result, not a failure.
  CPU-only torch still imports and runs.
