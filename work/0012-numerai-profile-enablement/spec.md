# 0012 — Numerai profile enablement

**Status:** Not started — captured 2026-08-24, parked until the owner picks the
project up. **The two decisions in §3 are gates: re-verify them against current
state and present them to the owner for sign-off BEFORE implementing anything.**

**Exit rule:** delete this folder, or move to [`docs/_archive/`](../../docs/_archive/),
when the work merges.

**Reference payload:** `numerai-setup.md` at the repo root — deliberately
**untracked** (gitignored via the `*-setup.md` pattern; it was removed from the
public tree in `6591e5a`). It is the source doc for domains, credential types,
scopes, and MCP endpoints. If it is missing from disk, stop and ask the owner
for it — do not reconstruct it from memory.

---

## 1. State as measured 2026-08-24 (re-verify on pickup)

**Done, live:**
- Squid `[numerai]` allowlist block — UNCOMMENTED in PROJECT-PERSISTENT
  (`proxy/allowed_domains.txt:284-297`), so open in every profile. Already
  refined beyond the setup doc (an extra S3 hostname variant added after real
  use, per the doc's own TCP_DENIED procedure). Egress needs nothing.
- Workspace `/workspace/numerai` exists in the nranthony profile, trusted by
  both agents, `.venv` present, actively used.

**Not done:**
- No `NUMERAI_*` entries in `sandbox_templates/common/secrets.env.template`;
  container env carries none (confirmed via the audit's
  `env_credential_named_keys` metadata — check that, never read a secrets.env).
- No MCP registration — zero `api-tournament` references in the profile's
  `claude.json`.
- Companion skills (numerai/example-scripts) not present. **Out of scope**
  unless the owner asks; they would arrive via the vendoring rules, not a
  direct fetch.

**Found along the way:** `numerai/pyproject.toml` in the workspace carries
`no-build = false` — a wholesale Gate 3 (wheels-only, ADR-0004) opt-out, one of
the five surfaced by G10p on its first run. §3 D2.

## 2. Remaining work (after §3 sign-off)

1. Add commented placeholders to `secrets.env.template`:
   `NUMERAI_PUBLIC_ID` + `NUMERAI_SECRET_KEY` (numerapi, two vars) and
   `NUMERAI_MCP_AUTH` (`Token PUBLIC$PRIVATE`, one combined var) — matching the
   template's existing placeholder style. Naming Numerai in the tracked tree is
   fine: the `[numerai]` allowlist block is already tracked, it is a public
   platform not a client, and it is not in the private-names list.
2. Register the MCP per-profile, per D1's decided form. Document the one-time
   command in `docs/extending-a-profile.md` as a worked example.
3. Resolve D2 in the workspace `pyproject.toml`.
4. Verify end-to-end from inside the container: `check_api_credentials` via the
   MCP, and a dataset-list call; then the doc's own follow-up — grep the Squid
   access log for `TCP_DENIED` S3 subdomains after a real download/upload and
   extend the allowlist block if any appear.
5. `just test-offline` and `scripts/profile.sh <p> verify` green (the
   secrets-template edit is not on the security-sensitive list, but the
   private-names suite scans `sandbox_templates/`).

## 3. DECISIONS — check, then present to the owner before implementing

**D1 — token storage shape (the one that can leak a credential).**
The setup doc's registration command expands `${NUMERAI_MCP_AUTH}` in the
*shell*, at add time — the literal token would land in `claude.json` on the
host. The intended form single-quotes the header so Claude Code expands the
variable at *runtime* from the container env, keeping the secret only in
`secrets.env` (0600), the pattern every other key here follows.
**Check first:** confirm the in-container Claude Code version actually performs
`${VAR}` expansion in HTTP-transport MCP headers (register against a dummy var
and inspect what `claude.json` stores + what the server receives). If it does
not, the fallback options (literal token in `claude.json` under the bind mount,
vs. wrapper script, vs. waiting on upstream) are materially different — lay
them out and let the owner pick. Do not default silently to the literal form.

**D2 — the `no-build = false` opt-out.**
The numerai workspace disables wheels-only, restoring install-time code
execution for every install in an egress window. Either it has a real sdist
need — then a one-line reason comment above the setting satisfies P01's WARN
path — or it is leftover and should be dropped. **Check first:** try the
project's install with the opt-out removed; present the result (works /
which package fails to resolve as a wheel) to the owner with the
recommendation.

## 4. Non-goals

- Any allowlist widening beyond the doc's own TCP_DENIED procedure.
- The companion skills (separate decision, vendoring rules apply).
- Tracking `numerai-setup.md` itself — it stays gitignored by design.
