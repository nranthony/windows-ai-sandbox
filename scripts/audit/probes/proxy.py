"""allowed_domains.txt review + squid.conf rule order.

White-box check on the staged proxy config. Required-core list, anti-pattern
detection, planning-mode-block-commented check, squid.conf ACL ordering.

windows-ai-sandbox accepts either of two equivalent CONNECT-gating patterns
in squid.conf:
  (a) explicit:  http_access deny CONNECT !SSL_ports
  (b) implicit:  http_access allow CONNECT SSL_ports allowed_domains
                 (combined with default `http_access deny all`)
Both yield the same blocked behaviour for CONNECT on port 80; the runtime
network.py probe is the authoritative signal."""
import os
import re

ALLOWED = "/workspace/temp_audit_package/proxy/allowed_domains.txt"
SQUID = "/workspace/temp_audit_package/proxy/squid.conf"

# Leaf hosts that MUST be on the allowlist — agent / Claude Code core paths.
REQUIRED_DOMAINS = [
    "api.anthropic.com",
    "statsig.anthropic.com",
    "github.com",
    "api.github.com",
    "registry.npmjs.org",
    "pypi.org",
    "files.pythonhosted.org",
]

# Section tags for the planning-mode block (commented-by-default; populated
# in Phase C). Currently expected absent.
PLANNING_TAGS = {"[git]", "[pypi]", "[npm]", "[nodejs]", "[apt]",
                 "[playwright-install]"}

# squid.conf rule markers — order-preserving. Both patterns supported.
EXPECTED_MARKERS_A = [
    "acl Safe_ports port",
    "http_access deny !Safe_ports",
    "acl SSL_ports",
    "acl CONNECT method",
    "http_access deny CONNECT !SSL_ports",
    "http_access allow allowed_domains",
    "http_access deny all",
]
EXPECTED_MARKERS_B = [
    "acl Safe_ports port",
    "http_access deny !Safe_ports",
    "acl SSL_ports",
    "acl CONNECT method",
    "http_access allow CONNECT SSL_ports allowed_domains",
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

    # Try both patterns; whichever fits cleanly wins.
    for label, markers in [("A_explicit_deny", EXPECTED_MARKERS_A),
                           ("B_allow_connect_ssl", EXPECTED_MARKERS_B)]:
        positions = _find_order(squid_lines, markers)
        line_nums = [p["line"] for p in positions]
        all_present = all(p > 0 for p in line_nums)
        in_order = all_present and line_nums == sorted(line_nums)
        if in_order:
            out.append(_check(
                "squid_acl_order",
                True,
                pattern=label,
                positions=positions,
            ))
            break
    else:
        # Neither pattern fit — emit DRIFT with both attempts for review.
        out.append({
            "section": "proxy",
            "name": "squid_acl_order",
            "verdict": "DRIFT",
            "details": {
                "pattern_A_explicit_deny": _find_order(squid_lines, EXPECTED_MARKERS_A),
                "pattern_B_allow_connect_ssl": _find_order(squid_lines, EXPECTED_MARKERS_B),
                "rationale": ("expected either explicit `deny CONNECT !SSL_ports` or "
                              "implicit `allow CONNECT SSL_ports allowed_domains` pattern"),
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
