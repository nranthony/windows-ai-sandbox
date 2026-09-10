# 0009 — Cross-Check Feedback & Verification Checklist

This document details findings, potential traps, and verification requirements identified during the architectural cross-check of [`work/0009-the-third-cli-runs-on-bun`](./spec.md) against the live repository state (`scripts/profile.sh`, `Dockerfile`, `seccomp.json`, `sandbox_templates/`, and offline test suites).

---

## 1. Config Precedence & Non-Overridable Policy (0011 / ADR-0007 F8)

* **Finding in Plan**: The plan targets the global configuration at `~/.config/opencode/opencode.json` (Precedence Level 2).
* **The Hazard**: In `opencode`, configuration precedence evaluates from lowest to highest:
  * Level 2: Global config (`~/.config/opencode/opencode.json`)
  * Level 4: Project/workspace config (`<workspace>/opencode.json` or `<workspace>/.opencode/opencode.json`)
  * Level 7: Managed config (system-wide non-overridable settings)
  Because Level 4 outranks Level 2, any repository workspace—or an agent executing file edits within the sandbox—could author an `opencode.json` that loosens or completely overrides the security restrictions.
* **Items to Double-Check**:
  1. Determine the exact Linux filesystem path for opencode's **managed config** (Level 7). The vendor docs document the macOS path (`/Library/Application Support/opencode/`), but not Linux (likely `/etc/opencode/` or `/usr/share/opencode/`).
  2. Verify merge semantics: When a project file defines `permission`, does `opencode` replace the entire permission map or merge key-by-key?
  3. If the managed config resides in a system directory (image-baked), bind-mount a per-profile host directory over it (similar to the directory mount pattern used for `proxy/`) so that policy convergence on `profile.sh up` remains live and functional.

---

## 2. Policy Convergence & Test Suite Locks

* **Superseded Subcommands**: The plan previously referenced a `reset-opencode` subcommand mirroring `reset-settings`. As of [ADR-0007](../../docs/adr/0007-policy-templates-are-source-of-truth-for-every-agent.md), all `reset-*` subcommands have been retired in favor of unified convergence:
  * `scripts/profile.sh <profile> converge`
  * Automatic convergence during `up`, `recreate`, `rebuild`, and `wipe`.
* **Adding to `AGENT_POLICY_DESCRIPTORS`**:
  * Location: [`scripts/profile.sh:633`](../scripts/profile.sh#L633).
  * Opencode descriptor row:
    ```bash
    "opencode|sandbox_templates/opencode/opencode.json|config/opencode/opencode.json|overwrite|autoupdate share provider permission|"
    ```
  * Mode must remain **`overwrite`**: `opencode` does not store user state in `opencode.json` (TUI preferences live in `tui.json`).
* **Test Suite Lock to Update**:
  * [`scripts/agent-policy.test.sh:231`](../scripts/agent-policy.test.sh#L231) contains a strict lock:
    ```bash
    [[ "$modes" == "overwrite merge " ]]
    ```
    Adding `opencode` (`overwrite`) will cause this test to fail unless updated to expect `"overwrite merge overwrite "` (or an updated pattern).
* **State Initialization**:
  * Ensure [`scripts/init-profile-state.sh`](../scripts/init-profile-state.sh) is updated alongside [`profile.sh::ensure_state`](../scripts/profile.sh#L876) to create `$BASE/config/opencode/` and bootstrap `opencode.json`.

---

## 3. Docker Build Layer Ordering & Flags

* **Build Flag Parity in `scripts/profile.sh`**:
  * There are **two** build flag parsers in `profile.sh`:
    1. Profile rebuild handler ([`profile.sh:1145–1155`](../scripts/profile.sh#L1145-L1155))
    2. Standalone `build` handler ([`profile.sh:1334–1360`](../scripts/profile.sh#L1334-L1360))
  * Both must be updated to accept `--opencode-version=X.Y.Z`, appending `--build-arg "OPENCODE_VERSION=${a#*=}"` and `--build-arg "AI_CLI_REFRESH=$(date +%s)"`.
  * Update help text and the unrecognized-flag error string (`profile.sh:1352`, `justfile:63`).
* **Dockerfile Order Chain (`dockerfile-order.test.sh`)**:
  * The order is load-bearing:
    `beads < AI_CLI_REFRESH < Gate 2 (/usr/etc/npmrc) < Gate 3 (/etc/uv/uv.toml)`
  * `opencode-ai` install **must sit above Gate 2**. Because Gate 2 sets `min-release-age=7`, placing the install below it will cause `opencode-ai@latest` to fail to resolve whenever an upstream release is younger than 7 days.
  * Update [`scripts/dockerfile-order.test.sh`](../scripts/dockerfile-order.test.sh) to include the new install string in `ANCHORS`.
* **Postinstall Script Enforcement**:
  * npm 12 in this base image sets `allow-scripts = [""]`.
  * `npm install -g --allow-scripts=opencode-ai "opencode-ai@${OPENCODE_VERSION}"` is mandatory because the npm package uses `postinstall.mjs` to extract the platform-specific Bun binary. Omitting `--allow-scripts` exits 0 at build time but leaves a non-working stub.
  * Always chain `&& opencode --version` in the same `RUN` command to ensure build failure on any postinstall defect.

---

## 4. Package Cache & Provider Installation Mechanics

* **Bind Mount Masking**:
  * Opencode downloads provider SDKs into `~/.cache/opencode/packages`.
  * Container path `/root/.cache` is bind-mounted to `${HOME}/.ai-sandbox/profiles/${PROFILE}/cache` ([`docker-compose.yml:63`](../docker-compose.yml#L63)).
  * In Linux/Docker, a host bind mount completely masks whatever was baked into that path in the image layer.
* **Architectural Trade-Off**:
  * **Option A (Plan's recommendation — Strict Audit Compliance)**: Run first-time provider fetch using `scripts/with-egress.sh <profile> --with npm -- 'opencode run ...'`. This enforces Gate 2, logs to `depgate.jsonl`, and persists in the profile's cache.
  * **Option B (Pre-seeding / Staging)**: If zero first-run network friction is desired, bake packages into an unmasked staging path (e.g. `/usr/local/share/opencode/seed-cache/`) during `docker build`, and copy them to `/root/.cache/opencode/packages` in `ensure_state()` if the profile cache lacks them. Note that this bypasses per-profile egress audit logging.

---

## 5. Permission Policy Semantics & Gaps

* **Last-Match-Wins vs Prefix-Match**:
  * Claude Code and Antigravity evaluate policies where denials strictly win and command prefixes are checked.
  * Opencode evaluates globs with **last-match-wins** semantics across categories (`read`, `edit`, `bash`, `glob`, `grep`, `webfetch`, `websearch`).
  * **Default-Allow Hazard**: In `opencode`, unlisted commands/tools default to `allow` (unlike Claude, which hands unknown commands to the auto-mode classifier).
  * The root policy must explicitly begin with:
    ```json
    "permission": {
      "*": "ask",
      "bash": {
        "*": "ask",
        ...
      }
    }
    ```
* **Coverage Verification**:
  * Cross-check all deny rules against `scripts/audit/probes/settings.py::REQUIRED_DENY` (package managers, `curl`, `wget`, `git push`, `rm -rf`, `sudo`, `docker`).
  * Ensure `bunx` and `bun x` are explicitly denied in `bash`.
  * Scope `read` permissions: Deny sensitive files (`.env`, `*.pem`, `*.key`, `id_rsa*`, `.credentials*`, `/root/.gemini/**`, `/root/.config/gh/**`).
  * Deny unbrokered web tools: `"webfetch": "deny"`, `"websearch": "deny"` to force browsing through the audited `webfetch` broker script (`docs/web-read-broker.md`).
* **Security Hook Engine Gap (Single-Layer vs Two-Layer Enforcement)**:
  * Claude and Antigravity operate under **two** security layers: static permissions + dynamic hook enforcement (`sandbox_templates/claude/hooks/deny-destructive.sh`).
  * Opencode is currently planned with **one** layer (static permissions only; hook dialect out of scope for Pass 1).
  * Document this gap prominently in `opencode.json` comments: Opencode will not be guarded against destructive file/manifest edits (e.g. adding malicious dependencies to `pyproject.toml` and resolving via an allowed build command).

---

## 6. Syscall Filter (`seccomp.json`) & Runtime Hardening

* `seccomp.json` enforces `defaultAction: SCMP_ACT_ERRNO` (allowlist only).
* Bun's JavaScriptCore memory primitives (`mmap`, `mprotect`, `madvise`, `memfd_create`) are present in the allowlist.
* **Risk**: Bun's Zig I/O layer. Syscalls such as `io_uring_*` are unlisted (default-denied), and `userfaultfd` is explicitly removed (`seccomp.json:133`).
* **Diagnostic Constraint**: `ptrace` is denied (`seccomp.json:119`), so `strace` cannot run inside the hardened container.
* **Phase 0 Requirement**:
  * Run an interactive session in a scratch container under real hardening (`scripts/run-ephemeral.sh`).
  * If the session fails mysteriously, run an unconfined scratch comparison (`--security-opt seccomp=unconfined`) to isolate whether a denied syscall is the cause.

---

## 7. Logistics: Keys & Egress Allowlist

* **API Key Management**:
  * Add `OPENROUTER_API_KEY` to [`sandbox_templates/common/secrets.env.template`](../sandbox_templates/common/secrets.env.template).
  * Configure `opencode.json` to source it via `{env:OPENROUTER_API_KEY}`.
  * `/root/.local` is a `noexec,nosuid,nodev` tmpfs; do not rely on opencode's `/connect` flow, which writes plaintext auth to `~/.local/share/opencode/auth.json` (wiped on recreate).
  * Remember: `env_file` is processed at container **create** time; adding the key requires `profile.sh <profile> recreate`.
* **Proxy Allowlist ([`proxy/allowed_domains.txt`](../proxy/allowed_domains.txt))**:
  1. `openrouter.ai` is already live under `[openrouter]`. Clean up the placeholder comment and register it in `scripts/audit/probes/proxy.py::REQUIRED_DOMAINS`.
  2. Add gated section:
     ```text
     # # --- Opencode CLI install/update [opencode-install] ---
     # opencode.ai
     ```
     Register `opencode-install` in `scripts/audit/probes/proxy.py::GATED_TAGS` and `dashboard/src/lib/proxy_categories.py`.
  3. `models.dev`: Do not add until Phase 0 tests verify that Bun's `fetch()` routes through Squid (`HTTP_PROXY`). If Bun bypasses the proxy, traffic is sinkholed by local DNS and the allowlist entry is inert.
