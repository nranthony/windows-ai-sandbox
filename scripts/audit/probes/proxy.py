"""allowed_domains.txt review + squid.conf rule order.

White-box check on the staged proxy config. Required-core list, anti-pattern
detection, planning-mode-block-commented check, squid.conf ACL ordering.

windows-ai-sandbox gates CONNECT to SSL_ports (443) via:
  http_access allow CONNECT SSL_ports allowed_domains
  http_access deny CONNECT
The explicit `deny CONNECT` is required — without it, CONNECT on port 80
falls through to `http_access allow allowed_domains` and succeeds.
The runtime network.py probe is the authoritative signal."""
import os
import re

ALLOWED = "/workspace/temp_audit_package/proxy/allowed_domains.txt"
SQUID = "/workspace/temp_audit_package/proxy/squid.conf"

# Domains that MUST be on the allowlist — agent / Claude Code core paths.
# Uses the leading-dot wildcard forms that actually appear in
# allowed_domains.txt (e.g. `.github.com` covers github.com + api.github.com).
REQUIRED_DOMAINS = [
    "api.anthropic.com",
    "statsig.anthropic.com",
    ".github.com",
    ".pypi.org",
    ".files.pythonhosted.org",
    ".registry.npmjs.org",
]

# Section tags for the planning-mode block (commented-by-default).
# [git], [pypi], [npm] are PROJECT-PERSISTENT in this repo (uncommented by
# default) — only gate tags that require manual intervention belong here.
PLANNING_TAGS = {"[playwright-install]"}

# squid.conf rule markers — order-preserving.
EXPECTED_MARKERS = [
    "acl Safe_ports port",
    "http_access deny !Safe_ports",
    "acl SSL_ports",
    "acl CONNECT method",
    "http_access allow CONNECT SSL_ports allowed_domains",
    "http_access deny CONNECT",
    "http_access allow allowed_domains",
    "http_access deny all",
]


def _check(name, ok, **details):
    return {
        "section": "proxy",
        "name": name,
        "verdict": "OK" if ok else "DRIFT",
        "details": details,
    }


def _find_order(squid_lines, markers):
    """Return list of (marker, line_index or -1) preserving order."""
    found = []
    for marker in markers:
        pos = -1
        for i, l in enumerate(squid_lines):
            if l.lstrip().startswith("#"):
                continue
            if marker.lower() in l.lower():
                pos = i
                break
        found.append({"marker": marker, "line": pos})
    return found


def run():
    out = []

    if not os.path.isfile(ALLOWED):
        return [{
            "section": "proxy",
            "name": "allowed_domains_present",
            "verdict": "UNKNOWN",
            "details": {"error": f"missing: {ALLOWED}"},
        }]

    with open(ALLOWED) as f:
        lines = f.read().splitlines()

    active = [l.strip() for l in lines
              if l.strip() and not l.strip().startswith("#")]

    # Required core entries.
    missing = [d for d in REQUIRED_DOMAINS if d not in active]
    out.append(_check(
        "required_core_present",
        not missing,
        missing=missing,
        checked=len(REQUIRED_DOMAINS),
    ))

    # Generic wildcard catch — anything starting with "." is INFO, not DRIFT
    # (this repo permits a few CDN parents that legitimately rotate subs).
    wildcards = [d for d in active if d.startswith(".")]
    out.append({
        "section": "proxy",
        "name": "wildcard_entries",
        "verdict": "INFO",
        "details": {
            "count": len(wildcards),
            "entries": wildcards,
            "rationale": ("review periodically — each wildcard is a CDN parent "
                          "that may rotate hostnames; tighten to leaf hosts where possible"),
        },
    })

    # IP literals or host.docker.internal — re-couples agent to host services.
    suspicious = [
        d for d in active
        if re.match(r"^\d+\.\d+\.\d+", d) or d == "host.docker.internal"
    ]
    out.append(_check(
        "no_ip_or_host_docker_internal",
        not suspicious,
        found=suspicious,
    ))

    # Planning-mode block must be commented in autonomous-mode default.
    in_planning = False
    current_tag = None
    uncommented_planning = []
    for raw in lines:
        s = raw.strip()
        m = re.search(r"\[[\w-]+\]", raw)
        if m and m.group(0) in PLANNING_TAGS:
            current_tag = m.group(0)
            in_planning = True
            continue
        if raw.startswith("# ===") or raw.startswith("# ---"):
            current_tag = None
            in_planning = False
            continue
        if in_planning and s and not s.startswith("#"):
            uncommented_planning.append({"line": raw, "tag": current_tag})

    out.append(_check(
        "planning_mode_commented",
        not uncommented_planning,
        uncommented=uncommented_planning[:10],
        count=len(uncommented_planning),
        rationale=("autonomous mode: planning-mode blocks should all be "
                   "commented; uncommented = with-egress.sh sentinel may be live"),
    ))

    # Per-profile additions — informational.
    extras = [d for d in active if d not in REQUIRED_DOMAINS]
    out.append({
        "section": "proxy",
        "name": "per_profile_additions",
        "verdict": "INFO",
        "details": {"count": len(extras), "domains": extras},
    })

    # squid.conf rule order
    if not os.path.isfile(SQUID):
        out.append({
            "section": "proxy",
            "name": "squid_conf_present",
            "verdict": "UNKNOWN",
            "details": {"error": f"missing: {SQUID}"},
        })
        return out

    with open(SQUID) as f:
        squid_lines = [l.rstrip() for l in f]

    positions = _find_order(squid_lines, EXPECTED_MARKERS)
    line_nums = [p["line"] for p in positions]
    all_present = all(p > 0 for p in line_nums)
    in_order = all_present and line_nums == sorted(line_nums)
    if in_order:
        out.append(_check(
            "squid_acl_order",
            True,
            positions=positions,
        ))
    else:
        out.append({
            "section": "proxy",
            "name": "squid_acl_order",
            "verdict": "DRIFT",
            "details": {
                "positions": positions,
                "rationale": ("expected: allow CONNECT SSL_ports, deny CONNECT, "
                              "allow allowed_domains, deny all — in that order"),
            },
        })

    # access_log present (forensic trail).
    has_log = any(
        "access_log " in l and not l.lstrip().startswith("#")
        for l in squid_lines
    )
    out.append(_check(
        "squid_access_log",
        has_log,
        rationale="forensic trail of every proxied request",
    ))

    return out


if __name__ == "__main__":
    import json
    import sys
    json.dump(run(), sys.stdout, indent=2)
    print()
