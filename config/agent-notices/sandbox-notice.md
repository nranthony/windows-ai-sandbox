<!-- BEGIN sandbox-notice (managed by windows-ai-sandbox — do not edit here) -->
## ⚠️ This repo may be edited by an agent inside `windows-ai-sandbox`

The agent's shell is restricted. The following **fail with permission-denied** —
do not attempt them, retry them, or hunt for a workaround; treat them as a human step:

- **No general internet.** `curl`/`wget` are denied; only a fixed allowlist is
  reachable (Anthropic, GitHub, PyPI, npm, PyTorch, Google/Antigravity). Don't fetch arbitrary URLs.
- **No dependency installs.** `pip install`, `uv add`/`uv pip install`, `npm install`/`npx`,
  `cargo/go install`, `pipx` are denied. If a package is missing, **stop and ask the
  human** to install it in the interactive shell (or via `scripts/with-egress.sh`).
- **No remote git.** `git push/pull/fetch/clone`, `git config`, `gh`, `glab` are denied.
  Commit locally; the human pushes.
- **No shell escapes.** `bash -c`, `sh -c`, `python -c`, `node -e`, `env`, `xargs`,
  `eval`, `awk`, `sed`, `perl`/`ruby` are denied (they're blocked as deny-list
  bypasses) — reaching for them instead of the direct tool also fails.
- **No secrets.** `.env`, `*.env.*`, `*.key`, `*.pem`, `**/credentials` are unreadable.

**What works:** read/edit files; `git add/commit/diff/log/show/checkout/stash`;
run tests & builds (`pytest`, `npm/pnpm run|test`, `node`, `python`, `uv run`,
`make`, `just`); `rg`, `find`, `jq`. Plan with installs/network/remote as human steps.
<!-- END sandbox-notice -->
