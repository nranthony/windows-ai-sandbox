# Sibling repo: macolima

`windows-ai-sandbox` and `macolima` are **two implementations of one threat
model on different substrates.** macolima is the origin; this repo was ported
from it. They share lineage but must never be blind-copied between — the value of
keeping both is that each is an independent check on the other.

## Shared (a finding in one is almost always latent in the other)

- **Network model** — `sandbox-internal` (`internal: true`, `172.30.0.0/24`) + Squid egress allowlist + DNS sinkhole + `extra_hosts` static IPs.
- **`seccomp.json`** — ported verbatim; any byte divergence is itself a finding.
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

diff "$MAC/seccomp.json"              "$HERE/seccomp.json"            # expect no diff
diff "$MAC/proxy/allowed_domains.txt" "$HERE/proxy/allowed_domains.txt"
diff <(ls "$MAC/scripts/audit/probes") <(ls "$HERE/scripts/audit/probes")  # probe-set gaps
```

See [`vscode-integration-security.md`](vscode-integration-security.md) for the
attach-time findings and [`sandbox-hardening-package.md`](../sandbox-hardening-package.md)
for the original macolima-origin remediation package.
