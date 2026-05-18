# scripts/audit/

Comprehensive sandbox audit. Runs ~80 deterministic probes inside the agent
container, emits one JSON document. Drives the agent-side report under the
`audit-sandbox` skill. Ported from macolima with WSL2 + root-in-container
adaptations.

## Three tiers

| Tier | What | When | Cost |
|---|---|---|---|
| 1 | `scripts/verify-sandbox.sh` | every `up` | ~3s, exit code |
| 2 | `scripts/audit/audit.sh` (this dir) | on demand | ~10s, JSON |
| 3 | agent reads JSON + CLAUDE.md, writes report.md | on demand | ~5k tokens |

Tier 1 is the fast tripwire — minimum viable invariants, breaks on the
common drift patterns. Tier 2 is the comprehensive structured probe.
Tier 3 is the judgment layer — distinguishing real drift from tripwire
artifacts, recommending tight diffs.

## Layout

```
scripts/audit/
├── audit.sh           # entry point — exec's aggregate.py
├── aggregate.py       # imports each probe, emits one merged JSON
├── probes/
│   ├── identity.py        # uid/gid/caps/seccomp_mode/sudo/SUID/AppArmor
│   ├── seccomp_static.py  # white-box on seccomp.json
│   ├── seccomp_runtime.py # runtime ctypes probes
│   ├── fs.py              # files, mounts, /proc, /sys, /dev, cgroups, PIDs
│   ├── network.py         # egress, DNS, DB siblings
│   ├── proxy.py           # allowed_domains.txt + squid.conf
│   ├── settings.py        # claude settings + per-project WebFetch + hook wiring
│   └── env.py             # env, VS Code Dev Containers leakage
└── README.md
```

## Output shape

Each probe's `run()` returns a list of finding dicts:

```python
{
  "section": str,        # identity / mac / seccomp_static / seccomp_runtime /
                         # fs / network / proxy / settings / env
  "name":    str,        # short stable identifier per finding
  "verdict": "OK" | "DRIFT" | "WEAK" | "UNKNOWN" | "N/A" | "INFO",
  "details": dict,
}
```

`aggregate.py` merges into:

```jsonc
{
  "info": {
    "stamp": "2026-05-16T12:34:56Z",
    "profile": "alpha",
    "container": "ai-sandbox-alpha",
    "uname": "Linux ... x86_64"
  },
  "summary": {"OK": 72, "DRIFT": 1, "WEAK": 1, "UNKNOWN": 0, "N/A": 5, "INFO": 4},
  "results": [/* findings */],
  "probe_errors": [/* only if a probe module crashed */]
}
```

## Verdict semantics

| Verdict | Meaning | What the agent does |
|---|---|---|
| `OK` | invariant holds | summarize, don't enumerate |
| `DRIFT` | documented invariant doesn't hold | cross-reference CLAUDE.md, decide real vs. tripwire bug, propose minimum-diff fix |
| `WEAK` | known weak spot | reference upstream TODO; not new drift |
| `UNKNOWN` | probe couldn't disambiguate | follow up with one targeted /tmp probe |
| `N/A` | optional component absent (e.g. DB sibling not running) | note, don't elevate |
| `INFO` | descriptive, not a verdict | pass through if user-relevant |

## Running

From the host:

```sh
scripts/profile.sh <profile> audit            # stage + run + save JSON to host
scripts/profile.sh <profile> audit --stage-only
```

From inside the container after staging:

```sh
bash /workspace/temp_audit_package/scripts/audit/audit.sh > /tmp/audit.json
```

For ad-hoc debugging of a single probe, run the module directly:

```sh
python3 /workspace/temp_audit_package/scripts/audit/probes/network.py
```

## Key differences from macolima

- **Container runs as root (UID 0)** under rootless Docker `userns=host`.
  The `identity` probe expects uid/gid=0, not 1000. The `settings.hook_file_immutable`
  check emits **WEAK** (not DRIFT) because root-in-container can write to
  `/usr/local/lib/claude-hooks/` — the kernel-write-protect that macolima
  relies on doesn't apply. The hook script is still defence-in-depth via
  the matcher and tamper rules; image rebuild restores it.
- **All persistent paths under `/root/...`**, not `/home/agent/...`.
- **No virtiofs.** The macolima `.vscode-server`/`.cache` ext4 checks are
  removed — WSL2 bind mounts are already ext4.
- **Hostname prefix `ai-sandbox-`**, not `claude-agent-`.

## Adding a new probe

1. Drop a `<name>.py` in `probes/`. Stdlib only.
2. Export a `run() -> list[dict]` returning findings.
3. Register in `aggregate.py`'s `PROBES` list.
4. Add an `if __name__ == "__main__"` debug block.

Probes must be: **read-only**, **stdlib only**, **fast** (<1s ideally),
**idempotent**, **self-contained**, **safe on missing inputs**.

## What this is not

This is not a security audit substitute. It checks *documented* invariants;
it doesn't try to discover new attack paths. The real boundary is the proxy
+ seccomp + cap_drop + rootless userns. The denylist, read-pattern blocks,
and these probes are defense in depth.
