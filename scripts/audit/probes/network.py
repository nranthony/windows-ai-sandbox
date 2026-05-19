"""Network egress, DNS, DB sibling reachability.

Sends raw HTTP/CONNECT through the Squid proxy via socket; doesn't use
curl (which is denied for the agent and would route around our intent).
Direct egress probes confirm `internal: true` on sandbox-internal."""
import socket

PROXY = ("egress-proxy", 3128)


def _check(name, ok, **details):
    return {
        "section": "network",
        "name": name,
        "verdict": "OK" if ok else "DRIFT",
        "details": details,
    }


def _http_via_proxy(method, host, port, path, timeout=8):
    """Send a raw request line through Squid (no CONNECT — bare GET/POST)."""
    s = socket.create_connection(PROXY, timeout=timeout)
    url = f"http://{host}:{port}{path}"
    req = (
        f"{method} {url} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        f"Connection: close\r\n\r\n"
    ).encode()
    s.sendall(req)
    data = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
        if len(data) > 16384:
            break
    s.close()
    return data.split(b"\r\n", 1)[0].decode("latin1", "replace")


def _connect_via_proxy(host, port, timeout=8):
    """Send a CONNECT through Squid. Returns the proxy's HTTP response line."""
    s = socket.create_connection(PROXY, timeout=timeout)
    s.sendall(
        f"CONNECT {host}:{port} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n\r\n".encode()
    )
    data = s.recv(4096)
    s.close()
    return data.split(b"\r\n", 1)[0].decode("latin1", "replace")


def _status_code(line):
    parts = line.split()
    return parts[1] if len(parts) >= 2 and parts[1].isdigit() else ""


def run():
    out = []

    # Proxy reachable at all.
    try:
        s = socket.create_connection(PROXY, timeout=3)
        s.close()
        proxy_up = True
    except Exception as e:
        proxy_up = False
        proxy_err = f"{type(e).__name__}: {e}"
    out.append(_check(
        "egress_proxy_reachable", proxy_up,
        host=PROXY[0], port=PROXY[1],
        **({} if proxy_up else {"error": proxy_err}),
    ))

    if proxy_up:
        # CONNECT to allowed host on 443 — should succeed (200).
        try:
            line = _connect_via_proxy("api.anthropic.com", 443)
            out.append(_check(
                "connect_allowed_443",
                _status_code(line) == "200",
                response=line,
            ))
        except Exception as e:
            out.append({
                "section": "network",
                "name": "connect_allowed_443",
                "verdict": "UNKNOWN",
                "details": {"error": f"{type(e).__name__}: {e}"},
            })

        # CONNECT to a NOT-on-allowlist host — must be 4xx.
        try:
            line = _connect_via_proxy("evil.example.invalid", 443)
            out.append(_check(
                "connect_disallowed_blocked",
                _status_code(line) in ("403", "400"),
                response=line,
            ))
        except Exception as e:
            out.append({
                "section": "network",
                "name": "connect_disallowed_blocked",
                "verdict": "UNKNOWN",
                "details": {"error": f"{type(e).__name__}: {e}"},
            })

        # GET on a non-Safe_port (allowed host:8080) — must be 403.
        # Tests `http_access deny !Safe_ports`.
        try:
            line = _http_via_proxy("GET", "api.anthropic.com", 8080, "/")
            out.append(_check(
                "non_safe_port_blocked",
                _status_code(line) in ("403", "400"),
                response=line,
                rationale="http_access deny !Safe_ports",
            ))
        except Exception as e:
            out.append({
                "section": "network",
                "name": "non_safe_port_blocked",
                "verdict": "UNKNOWN",
                "details": {"error": f"{type(e).__name__}: {e}"},
            })

        # CONNECT on port 80 — must be 4xx, MUST NOT tunnel.
        # Requires explicit `http_access deny CONNECT` after the SSL_ports
        # allow rule. Without it, CONNECT on 80 falls through to the
        # general `allow allowed_domains` and succeeds.
        try:
            line = _connect_via_proxy("api.anthropic.com", 80)
            code = _status_code(line)
            out.append(_check(
                "connect_80_blocked",
                code in ("403", "400"),
                response=line,
                rationale="CONNECT must be gated to SSL_ports (443)",
            ))
        except Exception as e:
            out.append({
                "section": "network",
                "name": "connect_80_blocked",
                "verdict": "UNKNOWN",
                "details": {"error": f"{type(e).__name__}: {e}"},
            })

    # Direct egress MUST fail — sandbox-internal is `internal: true`.
    for h, p in [("1.1.1.1", 443), ("8.8.8.8", 53)]:
        try:
            s = socket.create_connection((h, p), timeout=3)
            s.close()
            out.append(_check(
                f"direct_egress_{h.replace('.', '_')}_{p}_blocked",
                False,
                host=h, port=p,
                observed="UNEXPECTED CONNECT (direct egress reachable)",
            ))
        except Exception as e:
            out.append(_check(
                f"direct_egress_{h.replace('.', '_')}_{p}_blocked",
                True,
                host=h, port=p,
                observed=f"{type(e).__name__}: {str(e)[:80]}",
            ))

    # External DNS MUST be sinkholed. Docker's embedded resolver at 127.0.0.11
    # forwards to host DNS regardless of `internal: true`, which would be a
    # DNS exfil channel. Fix: dns: [127.0.0.1] sinkhole + extra_hosts.
    try:
        socket.gethostbyname("example.com")
        out.append(_check(
            "external_dns_blocked", False,
            observed="example.com resolved (DNS exfil channel open)",
            rationale="must NOT resolve external names",
        ))
    except (socket.gaierror, OSError):
        out.append(_check("external_dns_blocked", True))

    # Internal DNS MUST resolve via /etc/hosts (extra_hosts entries).
    for name in ["egress-proxy"]:
        try:
            ip = socket.gethostbyname(name)
            out.append(_check(f"internal_dns_{name}", True, ip=ip))
        except (socket.gaierror, OSError) as e:
            out.append(_check(
                f"internal_dns_{name}", False,
                error=f"{type(e).__name__}: {e}",
            ))

    # DB sibling reachability — informational. Absence is N/A, not drift.
    # This repo doesn't currently spin up DB siblings; left in for future use.
    for h, p in [("postgres", 5432), ("mongo", 27017)]:
        try:
            s = socket.create_connection((h, p), timeout=3)
            s.close()
            out.append({
                "section": "network",
                "name": f"db_{h}_reachable",
                "verdict": "OK",
                "details": {"host": h, "port": p, "status": "open"},
            })
        except Exception as e:
            out.append({
                "section": "network",
                "name": f"db_{h}_reachable",
                "verdict": "N/A",
                "details": {
                    "host": h, "port": p,
                    "observed": type(e).__name__,
                    "note": "DB sibling not running this session",
                },
            })

    return out


if __name__ == "__main__":
    import json
    import sys
    json.dump(run(), sys.stdout, indent=2)
    print()
