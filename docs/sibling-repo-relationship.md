# Sibling repo: macolima

`windows-ai-sandbox` and `macolima` are **two implementations of one threat
model on different substrates.** macolima is the origin; this repo was ported
from it. They share lineage but must never be blind-copied between — the value of
keeping both is that each is an independent check on the other.

## Shared (a finding in one is almost always latent in the other)

- **Network model** — `sandbox-internal` (`internal: true`, `172.30.0.0/24`) + Squid egress allowlist + DNS sinkhole + `extra_hosts` static IPs.
- **`seccomp.json`** — ported verbatim; any byte divergence is itself a finding.
  **Currently DIVERGED and it is our change to push**: `creat` was added here on
  2026-08-29 (`ce860b3`, [work/0017](../work/0017-tar-cannot-create-archives-seccomp-creat/spec.md))
  because `tar -cf <file>` failed EPERM in every profile. macolima has the same
  bug today and has not reported it. Closing this is a
  [work/0022](../work/0022-port-forward-to-macolima/spec.md) row, not a macolima finding.
- **VS Code attach-time leakage findings A–E** — SSH-agent forwarding, host `~/.gitconfig` copy, IPC credential-helper injection, orphan UID-0 shell, Copilot IDE state. These are **VS Code Dev Containers behavior, platform-independent.**
- **In-container mitigations** — `openssh-client` purged, `credential.helper` scrub on every `up`, `.zshrc` `unset SSH_AUTH_SOCK`.
- **Three-tier verification** — `verify-sandbox.sh` tripwire → audit probes → agent-side judgment skill.

## Divergent (copying these *causes* flaws)

| Axis | macolima | here |
|---|---|---|
| Host / runtime | macOS + Colima VM + **rootful** Docker | Windows + WSL2 + **rootless** Docker |
| Container user | `agent` UID 1000, **non-root** | **root** UID 0 = host UID 1000 (`userns=host`) |
| Privilege boundary | unprivileged user + dropped caps | rootless userns remap + dropped caps |
| `remoteUser` | `agent` | **`root`** (copying `agent` → remaps to `nobody`, breaks writes) |
| VS Code config carrier | per-repo attach `devcontainer.json` | host-side: user `settings.json` + attached-container config (no repo `devcontainer.json`) |
| Host settings path | `~/Library/Application Support/Code/User/` | `%APPDATA%\Code\User\` |
| Names / prefix / state | `claude-agent-<p>`, `macolima-<p>`, `/Volumes/DataDrive/.claude-colima/` | `ai-sandbox-<p>`, `ai-sandbox-<p>`, `~/.ai-sandbox/` |
| FS quirk fought | virtiofs (named volumes for cache/.vscode-server) | WSL2 inode/ownership |
| Allowlist wildcard entries | any leading-dot entry is **DRIFT** (`proxy/no_vendor_wildcards`) | reported as **INFO** (`proxy/wildcard_entries`) — see below |
| Hook write-protect | **kernel-enforced**: hook is UID 0, agent is UID 1000 | **not enforceable**: agent IS root. The defence here is that the engine is baked into the image, so an edit dies on recreate |
| Allowlist size | 15 tagged blocks, 278 lines | 32 tagged blocks, 719 lines |
| Offline test suites | 1 (`deny-destructive.test.sh`) | 10, run by `just test-offline` |

**Why wildcards are INFO here and DRIFT there.** macolima's allowlist can be
kept to leaf hosts. This one cannot: `.fal.media` (`70e9213`) is a delivery CDN
whose host set is not enumerable, and collapsing it to one wildcard *was* the
security change. Making a leading dot fail here would produce a permanently-red
probe, and by this repo's own standard — "a check that cries wolf on its first
run is a check that gets ignored" (`scripts/vendor-tools.sh`) — that is worse
than no check. Do not "fix" the INFO verdict by copying macolima's, and do not
loosen macolima's to match this one: its leaf-only discipline is achievable on
its smaller surface and should stay.

**The hook row is the one most likely to be ported wrongly.** macolima's
`settings/hook_file_immutable` probe (root-owned, not agent-writable) measures a
real kernel guarantee. Ported here it would measure nothing — see
[`work/0021`](../work/0021-pull-back-controls-from-macolima/spec.md) §5, where
D2 holds the open question of what the equivalent check should be.

## How to mine macolima for flaws we might miss

1. **Pull macolima's audit/verify history first.** When its tripwire or audit
   catches a new leak (e.g. the 2026-04-25 H1 credential-helper drift, SSH-socket
   UUID re-injection), assume it applies here unless a divergence axis rules it
   out — these are the platform-independent ones.
2. **Diff the controls, not the prose:**
   - `diff` the two `seccomp.json` (expect identical),
   - `diff` the two `proxy/allowed_domains.txt` (a domain opened in one but not the other is allowlist drift),
   - compare `scripts/audit/probes/` and `verify-sandbox.sh` check-for-check — **any probe macolima has that we lack is a candidate gap**,
   - compare the required host VS Code keys (macolima's `gitCredentialHelperConfigLocation: none` is what surfaced ours).
3. **Filter every candidate through the privilege axis.** A SUID-binary finding
   is load-bearing in macolima (non-root agent) but largely inert here
   (container-root under rootless); conversely a rootless-userns concern won't
   appear there. Don't import a control whose threat doesn't exist on this
   substrate — and don't dismiss one just because macolima frames it in
   `agent`-user terms.

## Quick cross-check commands

Assuming both repos are checked out as siblings (adjust paths):

```bash
MAC=~/repo/sandbox/macolima
HERE=~/repo/sandbox/windows-ai-sandbox

# seccomp: expect ONLY the `creat` line + its comment until work/0022 lands.
# Anything else is a finding.
diff "$MAC/seccomp.json"              "$HERE/seccomp.json"

# Allowlists diverge by design (15 tagged blocks there, 32 here) — a raw diff is
# noise. Compare the TAG SETS, then read only the blocks that differ:
# `[tag]` and `[a-z-]` are prose/regex fragments in this repo's header, not blocks.
tags() { grep -oE '\[[a-z0-9_.-]+\]' "$1" | grep -vxE '\[tag\]|\[a-z-\]' | sort -u; }
diff <(tags "$MAC/proxy/allowed_domains.txt") <(tags "$HERE/proxy/allowed_domains.txt")

# Probe FILES, not probe CHECKS. A file-level diff misses renames and in-place
# strengthening in both directions — it is what made work/0001 §A9 four-fifths
# wrong. Use the check-level extraction in work/0021 §2 instead.
diff <(ls "$MAC/scripts/audit/probes") <(ls "$HERE/scripts/audit/probes")
```

## The live backlog in both directions

Neither repo should be re-compared from scratch; two work items hold the
measured state as of 2026-08-31:

- [`work/0022`](../work/0022-port-forward-to-macolima/spec.md) — here → macolima.
  Re-validates macolima's own `work/0001` (planned 2026-08-23, never started),
  re-anchored on `main@eda42dd`. Carries the substrate filter, the exclusion
  list, and the handoff document the macOS side needs.
- [`work/0021`](../work/0021-pull-back-controls-from-macolima/spec.md) — macolima
  → here. Parked until 0022's handoff returns. Its §2 holds the check-level
  extraction that should replace every future eyeball comparison.

See [`vscode-integration-security.md`](vscode-integration-security.md) for the
attach-time findings and [`sandbox-hardening-package.md`](../sandbox-hardening-package.md)
for the original macolima-origin remediation package.
