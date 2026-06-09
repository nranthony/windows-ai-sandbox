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

# Base-minimum domains the autonomous agent CANNOT run without — the always-on
# [claude] + [gemini] blocks. Leaf hosts per audit M3 (no parent wildcards).
# Package / code-fetch ecosystems (PyPI, pythonhosted, npm, github, apt) are
# deliberately NOT here: they are gated OFF by default and opened per-stage via
# the Streamlit dashboard (dashboard/src/pages/04_proxy_allowlist.py) or
# with-egress.sh. Asserting them as "required" would fight that supply-chain
# stance — see GATED_TAGS / gated_blocks_default_off below.
REQUIRED_DOMAINS = [
    # [claude] — Claude Code core API + auth/console surface
    "api.anthropic.com",
    "console.anthropic.com",
    "statsig.anthropic.com",
    "api.claude.com",
    "platform.claude.com",
    "claude.ai",
    # [gemini] — Gemini CLI OAuth + Code Assist
    "accounts.google.com",
    "oauth2.googleapis.com",
    "www.googleapis.com",
    "codeassist.google.com",
    "developers.google.com",
    "cloudcode-pa.googleapis.com",
]

# Gated blocks: package / code-fetch egress (the supply-chain attack surface for
# autonomous runs). These MUST stay commented (OFF) in the base; they are opened
# deliberately, per-stage, via the Streamlit dashboard or with-egress.sh, then
# closed. Tags without brackets — matched against the `[tag]` block header.
GATED_TAGS = {"git", "pypi", "pytorch", "npm", "nvidia", "numerai",
              "apt", "playwright-install", "quarto-install"}

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

    # Gated (package/install) blocks must be commented (OFF) in the autonomous
    # base. Walk the file tracking the current [tag] block; flag any uncommented
    # domain under a GATED_TAGS block — that means package/code-fetch egress is
    # live right now. WEAK (not DRIFT): the dashboard / with-egress.sh open these
    # deliberately per-stage, so the auditor confirms it was intentional rather
    # than residual. This is the "nothing instated without my knowledge" guard.
    current_tag = None
    open_gated = []
    for raw in lines:
        s = raw.strip()
        m = re.search(r"\[([\w-]+)\]", raw)
        if m and "---" in raw:                 # a `[tag]` block header
            current_tag = m.group(1)
            continue
        if raw.startswith("# ===") or (raw.startswith("# ---") and not m):
            current_tag = None                 # section/divider ends the block
            continue
        if current_tag in GATED_TAGS and s and not s.startswith("#"):
            open_gated.append({"domain": s, "tag": current_tag})

    open_tags = sorted({e["tag"] for e in open_gated})
    out.append({
        "section": "proxy",
        "name": "gated_blocks_default_off",
        "verdict": "OK" if not open_gated else "WEAK",
        "details": {
            "open_blocks": open_tags,
            "open_domains": [e["domain"] for e in open_gated][:20],
            "count": len(open_gated),
            "rationale": ("package/install egress (PyPI, pythonhosted, npm, "
                          "github, apt, …) must stay OFF in the autonomous base "
                          "to block supply-chain installs; open = confirm it was "
                          "a deliberate dashboard / with-egress.sh toggle for an "
                          "install stage, not residual"),
        },
    })

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
