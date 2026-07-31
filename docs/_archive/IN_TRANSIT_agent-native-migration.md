# IN_TRANSIT — agent-native repo migration

**Status:** planned, not started. This repo will adopt the agent-native conventions from
[`nranthony/agentic-conventions`](https://github.com/nranthony/agentic-conventions)
(reference: `reference/agentic_native_repo_scaffold.md`). Hand this file to an agent to
execute later.

Created 2026-07-02.

---

## What this is, in one line

Turn `windows-ai-sandbox` into an agent-native repo: split its single ~18KB `CLAUDE.md`
into a proper `AGENTS.md` + thin pointer, add a map, give the subprojects their own
entry points, and tidy where the container-injection templates live.

## Why

Today: one big `CLAUDE.md` doing everything, no `AGENTS.md`, no architecture map, and the
sandbox-injection templates (`config/`) are mixed in with host-side config. No clean entry
point or mental map for agents (or humans).

## Guiding rules (from the conventions repo)

- Apply the conventions **by hand**, adapting to this repo's real shape — there is no
  scaffolder script (that was deliberately removed; it had footguns).
- Keep the root `AGENTS.md` **lean**; push subproject detail down to nested `AGENTS.md`
  (nearest file wins).
- Every `CLAUDE.md` is just a two-line `@AGENTS.md` stub, written by hand. **Never** let a
  stub overwrite substantive content — the current 18KB `CLAUDE.md` must be *moved*, not
  flattened.
- Adopt the **lean core** first; treat the heavier pieces (rfcs/, design/, work/, CI,
  CODEOWNERS) as opt-in and skip anything this repo doesn't need.

---

## The steps (in order)

### Safe / mechanical / high-value — do these first
- [ ] **1. Split the big `CLAUDE.md`.** Move its content into a new root `AGENTS.md` (the
      real source of truth). Replace `CLAUDE.md` with the two-line `@AGENTS.md` stub.
- [ ] **2. Trim the root `AGENTS.md` to lean.** Keep golden rules, the security-sensitive
      file list, and links out. Move subproject specifics down (step 4).
- [ ] **3. Add `ARCHITECTURE.md`.** One diagram of the WSL2 → rootless-Docker → Squid-proxy
      boundaries so an agent gets the map without reading everything.
- [ ] **4. Nested `AGENTS.md` for the two subprojects.** `dashboard/` (Streamlit + uv) and
      `container_testing/` (CUDA + uv) each get a local `AGENTS.md` + thin `CLAUDE.md`.
- [ ] **6. Write the security protocol into root `AGENTS.md`.** The "these files are
      security-sensitive, verify before changing" list (`Dockerfile`, `docker-compose.yml`,
      `seccomp.json`, `proxy/allowed_domains.txt`, `scripts/profile.sh`,
      `scripts/verify-sandbox.sh`) and the required verify/audit steps. This is the
      sandbox-specific part that does NOT belong in the generic conventions repo.
- [ ] **7. Gitignore local files.** `AGENTS.local.md`, `**/AGENTS.local.md`,
      `.claude/settings.local.json`.

### Riskier — do as a separate commit, with testing
- [ ] **5. Rename `config/` → `sandbox_templates/`.** Separates "injected into containers at
      spin-up" from host-side config. Then fix every path reference in the scripts that read
      it — at least `scripts/profile.sh`, `scripts/init-profile-state.sh`,
      `scripts/stage-audit-package.sh` (grep for `config/` first; there are more). The
      container spin-up / reset-settings / reset-skills flows must still work afterward —
      test with a real `profile.sh <p> up` / `verify` before committing.

### Optional / later
- [ ] **8. `.agents/skills/`** for recurring host tasks — profile lifecycle, security audit,
      Squid allowlisting. Skip until actually wanted; don't create empty dirs.

---

## Recent changes to carry through the migration (2026-07-03)

Tooling landed since this plan was written (commits `16878e9`, `cdeb446`). None of it
changes the migration steps, but the split/rename must preserve it:

- **AI CLI refresh layer (Dockerfile).** `claude` + `agy` now install in the *last*
  Dockerfile layer, gated by `ARG AI_CLI_REFRESH` + `ARG CLAUDE_VERSION`, so a version bump
  rebuilds only the tail. `Dockerfile` is already on the step-6 security-sensitive list — the
  migrated `AGENTS.md` security protocol should keep flagging it (the build args are a new
  cache-busting surface, not a new privilege).
- **New `profile.sh` commands/flags.** `build --refresh-ai` / `--claude-version=X.Y.Z` /
  `--recreate-running`, and a profile-less **`recreate-all`** (force-recreate every running
  profile onto the current image). When step 1 moves `CLAUDE.md` → `AGENTS.md`, the expanded
  "Image rebuilds" block goes with it verbatim. `scripts/profile.sh` is already step-6
  security-sensitive — no list change needed.
- **No new path references.** These changes touched only `Dockerfile`, `scripts/profile.sh`,
  `justfile`, `CLAUDE.md` — none add a `config/` read, so the step-5 rename grep is unaffected.

## Notes / decisions
- Sequence matters: land the doc split (1–4, 6–7) first as one commit; do the `config/`
  rename (5) separately so a path-reference miss can't be confused with the doc changes.
- `GEMINI.md` is not needed (Antigravity reads `AGENTS.md` natively). Delete any that exist.
- The old `agent_repo_conventions_advice.md` in this repo root is the longer write-up this
  plan is distilled from — keep it as reference, or fold it in and delete once migrated.
- In-flight work is tracked in ClickUp, so `work/`, `docs/rfcs/`, `docs/design/` are skipped.
