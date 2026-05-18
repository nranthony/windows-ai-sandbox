#!/usr/bin/env python3
"""Run all audit probes and emit one JSON document.

Probes are stdlib-only Python modules under probes/. Each exposes a run()
function returning a list of finding dicts:

    {"section": str,
     "name":    str,
     "verdict": "OK" | "DRIFT" | "WEAK" | "UNKNOWN" | "N/A" | "INFO",
     "details": {...}}

aggregate.py imports each probe in turn, catches per-module crashes so one
broken probe doesn't sink the run, and emits:

    {"info":    {stamp, profile, container, uname, ...},
     "summary": {OK: N, DRIFT: N, ...},
     "results": [...findings...],
     "probe_errors": [...]}      # only if any probe crashed

Usage:
    python3 aggregate.py            # pretty (indented, default)
    python3 aggregate.py --compact  # one-line JSON
"""
import datetime
import importlib
import json
import os
import pathlib
import subprocess
import sys

# Ordered for stable report layout. Maps to the audit prompt's §-numbered
# sections; aggregate output is sectioned by `section` key, not by probe.
PROBES = [
    "identity",         # §1  identity, privileges, SUID, AppArmor (§2 folded in)
    "seccomp_static",   # §3a seccomp.json white-box
    "seccomp_runtime",  # §3b runtime ctypes probes
    "fs",               # §4 §5 §6 §7 §8 — files, mounts, /proc, /sys, /dev, cgroups, PIDs
    "network",          # §9a-c §9e — egress, DNS, DB siblings
    "proxy",            # §9d §9g — allowed_domains.txt + squid.conf
    "settings",         # §12 — claude settings, template diff, per-project WebFetch
    "env",              # §13 — env, VS Code Dev Containers leakage
]


def _profile_from_hostname():
    """Container hostname is `ai-sandbox-<profile>` per docker-compose."""
    try:
        h = open("/etc/hostname").read().strip()
        if h.startswith("ai-sandbox-"):
            return h[len("ai-sandbox-"):]
    except OSError:
        pass
    return None


def _info():
    """Informational fields the report needs verbatim."""
    info = {
        "stamp": datetime.datetime.now(datetime.timezone.utc)
                          .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "profile": (os.environ.get("PROFILE")
                    or _profile_from_hostname()
                    or "unknown"),
        "container": os.environ.get("HOSTNAME", ""),
    }
    try:
        info["uname"] = subprocess.run(
            ["uname", "-a"], capture_output=True, text=True, timeout=2
        ).stdout.strip()
    except Exception:
        info["uname"] = ""
    return info


def main():
    pretty = "--compact" not in sys.argv

    probes_dir = pathlib.Path(__file__).parent / "probes"
    sys.path.insert(0, str(probes_dir))

    results = []
    errors = []
    for name in PROBES:
        try:
            mod = importlib.import_module(name)
            findings = mod.run()
            if not isinstance(findings, list):
                raise TypeError(
                    f"{name}.run() returned {type(findings).__name__}, expected list"
                )
            results.extend(findings)
        except Exception as e:
            errors.append({
                "module": name,
                "error": f"{type(e).__name__}: {e}",
            })

    summary = {}
    for r in results:
        v = r.get("verdict", "UNKNOWN")
        summary[v] = summary.get(v, 0) + 1

    out = {
        "info": _info(),
        "summary": summary,
        "results": results,
    }
    if errors:
        out["probe_errors"] = errors

    if pretty:
        json.dump(out, sys.stdout, indent=2, default=str)
    else:
        json.dump(out, sys.stdout, default=str)
    print()


if __name__ == "__main__":
    main()
