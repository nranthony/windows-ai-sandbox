# Revised Implementation Advice: Agent-Native Repo Conventions for `windows-ai-sandbox`

This revised report incorporates the peer review suggestions to refine the **Agent-Native Repo Conventions** specifically for this repository's security-sensitive infrastructure.

---

## 1. Key Refinements and Responses to Feedback

### A. Host-Agent vs. Sandbox-Agent Boundary
We maintain the high-value separation:
- **Host Agent Context**: Pairs with the developer to edit the `windows-ai-sandbox` repository on the WSL2 host. Guided by `AGENTS.md` and `.agents/skills/`.
- **Sandbox Agent Context**: Executes inside the container runtime to run tools/evals. Configured via templates injected on startup.

### B. Replace Symlinks with Generated Import Files
Symlinks can cause issues on Windows hosts, IDE agent checkouts, or zip exports. 
* **Recommendation**: Replace symlinks with generated thin entry points:
  - `CLAUDE.md` will contain the `@AGENTS.md` include path.
  - Delete `GEMINI.md` where possible, as modern CLI agents (like Antigravity) read `AGENTS.md` natively. If needed, we generate it with the same `@AGENTS.md` pattern.
* **Sync Script**: Rewrite `scripts/sync-agent-files.sh` to generate these text files instead of creating symlinks.

### C. Do Not Hardcode File URLs
* **Recommendation**: Avoid absolute paths like `file:///home/<username>/...` in committed files. Instead, use relative markdown links (e.g., `[dashboard/AGENTS.md](dashboard/AGENTS.md)`). They are fully portable across checkouts and render as clickable links in VS Code, GitHub, Cursor, and Gemini/Antigravity.

### D. Version Sandbox Templates Separately
Currently, the templates injected into the sandboxes live in `config/` (alongside dotfiles, settings, hooks, and skills).
* **Recommendation**: Reorganize this directory to clearly distinguish sandbox assets from host-side configurations. Create a `sandbox_templates/` directory to structure these profiles:
  ```text
  sandbox_templates/
  ├── common/               # Shared settings (e.g., .zshrc, db.env.template)
  ├── claude/               # Claude Code specific profiles (claude-settings.json)
  └── skills/               # Injected runtime skills (audit-sandbox/SKILL.md)
  ```
  We will then update path definitions inside `scripts/init-profile-state.sh`, `scripts/profile.sh`, and `scripts/stage-audit-package.sh`.

### E. Operationalize Security Language and Golden Rules
Explicitly list security-sensitive files and mandate pre-change verification steps to prevent agents from inadvertently compromising container isolation or bypassing `profile.sh`.

### F. Repository Host Skills Library & Architecture Map
* **Host Skills**: Instead of letting `AGENTS.md` bloat, keep it short and point the host agent to self-contained guidebooks under `.agents/skills/`.
* **concise Architecture Map**: Create [ARCHITECTURE.md](ARCHITECTURE.md) containing the primary system diagram so agents have an instant, token-efficient mental map of the WSL2-to-Squid network boundaries.

---

## 2. Updated Directory Layout

```
.
├── AGENTS.md                      # ← HOST SOURCE OF TRUTH (High-level conventions & security protocols)
├── CLAUDE.md                      # → Generated thin entrypoint (contains "@AGENTS.md")
├── ARCHITECTURE.md                # ← NEW: System diagram and data-flow map
├── README.md                      # Human-facing introduction (how to install, setup)
│
├── .agents/
│   └── skills/                    # Host agent skills (reusable guidebooks for workspace operations)
│       ├── profile-lifecycle.md   # Lifecycle CLI usage details
│       ├── security-audit.md      # Tier 1 & 2 verification tasks
│       └── squid-management.md    # Allowed domain configuration edits
│
├── .claude/
│   └── settings.local.json        # Gitignored local dev settings
│
├── sandbox_templates/             # ← RESTRUCTURED: Rules injected into active sandboxes
│   ├── common/                    # Shared dotfiles (.zshrc, .p10k.zsh)
│   ├── claude/                    # claude-settings.json, hooks
│   └── skills/                    # Templates for sandbox-injected skills (audit-sandbox/)
│
├── scripts/
│   ├── sync-agent-files.sh        # ← NEW: Python or Bash file generator for CLAUDE.md
│   └── ...                        # Updated init-profile-state.sh & profile.sh targeting sandbox_templates/
│
├── dashboard/                     # Web Control Panel (Streamlit)
│   ├── AGENTS.md                  # ← LOCAL: Streamlit app conventions, uv commands
│   └── CLAUDE.md                  # → Generated thin entrypoint (contains "@AGENTS.md")
│
└── container_testing/             # GPU/CUDA Verification env (uv project)
    ├── AGENTS.md                  # ← LOCAL: CUDA testing conventions, uv details
    └── CLAUDE.md                  # → Generated thin entrypoint (contains "@AGENTS.md")
```

---

## 3. Revised File Drafts

### A. Root `AGENTS.md`
```markdown
# windows-ai-sandbox

Hardened Windows AI development environment infrastructure using WSL2 Ubuntu, rootless Docker, Squid-gated egress, and CPU/GPU passthrough.

## System Architecture
For a visual overview of the WSL2 virtual machine boundary, rootless Docker user namespace mapping, and Squid proxy interfaces, refer to [ARCHITECTURE.md](ARCHITECTURE.md).

## Subprojects & Sub-contexts
To reduce context pollution, implementation details for subprojects are kept local:
- **Control Dashboard**: streamlit console setup and logic rules live in [dashboard/AGENTS.md](dashboard/AGENTS.md).
- **Container Verification**: CUDA/GPU test notebook procedures live in [container_testing/AGENTS.md](container_testing/AGENTS.md).

## Golden Rules
1. **Authoritative Orchestration**: `scripts/profile.sh` is the single entry point for lifecycle management.
   - **Do NOT**: Call `docker compose` directly, manually configure `COMPOSE_PROJECT_NAME`, or spawn container resources outside `profile.sh`.
   - **Extension Principle**: If a feature is missing, extend `scripts/profile.sh` instead of bypassing it with custom compose commands.
2. **Conventions**: Prioritize matching existing patterns in the file you are editing over external style guides.

## Security-Sensitive Changes
Modifications to files governing security controls require strict protocol verification:
- **Sensitive Files**:
  - `Dockerfile`
  - `docker-compose.yml`
  - `seccomp.json`
  - `proxy/allowed_domains.txt`
  - `scripts/profile.sh`
  - `scripts/verify-sandbox.sh`
- **Verification Protocol**: Any change to these files requires:
  1. A written explanation in the commit description detailing the security impact of the change.
  2. Executing the verification suite: `scripts/profile.sh <profile> verify` (Tier-1 tripwire) and `scripts/profile.sh <profile> audit` (Tier-2 probes).
  3. Updating relevant architectural files if default hardening settings are altered.

## Host Agent Skills Reference
Detailed guides for operational tasks are offloaded to our skills library:
- **Profile Management**: See [.agents/skills/profile-lifecycle.md](.agents/skills/profile-lifecycle.md)
- **Hardening and Verification**: See [.agents/skills/security-audit.md](.agents/skills/security-audit.md)
- **Squid Proxy Allowlisting**: See [.agents/skills/squid-management.md](.agents/skills/squid-management.md)

@AGENTS.local.md
```

### B. Root `CLAUDE.md`
```markdown
# CLAUDE.md
@AGENTS.md
```

### C. `dashboard/AGENTS.md`
```markdown
# Sandbox Dashboard

Host-side Streamlit control console for managing running profiles and proxy allowlists.

## Tech Stack
- **Language**: Python >= 3.12
- **Framework**: Streamlit
- **Package Manager**: `uv` (use `uv run` and `uv sync`, not bare pip)
- **Engine**: Python Docker SDK (communicates with host WSL2 rootless Docker daemon)

## Workflow Commands
- **Environment Setup**: `uv sync`
- **Run Dashboard**: `uv run streamlit run src/app.py`
- **Port Bindings**: Streamlit binds to `127.0.0.1:8501` (via `.streamlit/config.toml`).

## Developer Guidelines
- **Docker communication**: Connect to the rootless daemon socket at `unix:///run/user/1000/docker.sock`. Do not run as root.
- **Proxy updates**: Modification of proxy settings must edit `proxy/allowed_domains.txt` relative to the repository root, followed by running `docker exec egress-proxy-<profile> squid -k reconfigure`.
```

### D. `container_testing/AGENTS.md`
```markdown
# CUDA Container Testing Workspace

Validation workspace for GPU passthrough and CUDA availability inside container builds.

## Tech Stack
- **Language**: Python >= 3.12
- **Package Manager**: `uv` (utilizes PyTorch CUDA 12.6 wheels index)
- **Dependencies**: `torch`, `torchvision`, `ipykernel`

## Workflow Commands
- **Setup environment**: `uv sync`
- **Verify GPU inside active sandbox container**:
  ```bash
  scripts/profile.sh <profile> exec bash -lc 'cd /workspace/windows-ai-sandbox/container_testing && uv run python -c "import torch; print(torch.cuda.is_available())"'
  ```
```

### E. `scripts/sync-agent-files.sh`
```bash
#!/usr/bin/env bash
# scripts/sync-agent-files.sh
# Generate CLAUDE.md files pointing to their sibling AGENTS.md files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

sync_dir() {
  local dir="$1"
  [ -f "$dir/AGENTS.md" ] || return 0
  
  echo "Writing entry point files in: $dir"
  # Write CLAUDE.md pointing to AGENTS.md
  cat <<EOF > "$dir/CLAUDE.md"
# CLAUDE.md
@AGENTS.md
EOF

  # Clean up legacy GEMINI.md files if they exist (modern agents use AGENTS.md natively)
  if [ -f "$dir/GEMINI.md" ]; then
    rm -f "$dir/GEMINI.md"
  fi
}

cd "$REPO_ROOT"
# Sync Root
sync_dir "."

# Sync Subdirectories with AGENTS.md
while IFS= read -r -d '' f; do
  dir="$(dirname "$f")"
  [ "$dir" = "." ] && continue
  sync_dir "$dir"
done < <(find . -name AGENTS.md -not -path './.git/*' -print0)

echo "Agent file synchronization complete."
```

### F. `.gitignore` updates
```diff
# environmental user information
.env
# local shells for personal setup
.local*
# fashion mnist testing data
data/

**.pyc
**/**.pyc
+
+ # Agent-Native Local Configurations
+ AGENTS.local.md
+ **/AGENTS.local.md
+ .claude/settings.local.json
```

---

## 4. Revised Migration Plan

1. **Initialize `.gitignore` changes**.
2. **Move current `CLAUDE.md` to `AGENTS.md`** and strip out specific subproject workflows.
3. **Generate `CLAUDE.md`** containing `@AGENTS.md`.
4. **Create `dashboard/AGENTS.md` and `container_testing/AGENTS.md`**.
5. **Create the sync script** (`scripts/sync-agent-files.sh`) and make it executable.
6. **Move `config/` subfolders** to `sandbox_templates/` and update script references inside:
   - `scripts/init-profile-state.sh`
   - `scripts/profile.sh`
   - `scripts/stage-audit-package.sh`
7. **Create `ARCHITECTURE.md`** and `.agents/skills/` operational guides.
8. **Run sync script and commit**.
