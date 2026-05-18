"""seccomp.json white-box.

Reads the staged seccomp.json (under /workspace/temp_audit_package/) and
checks the default action, required-allow set, and required errno mappings.
Runtime confirmation is in seccomp_runtime.py."""
import json
import os

SECCOMP_PATH = "/workspace/temp_audit_package/seccomp.json"

# Syscalls that MUST be allowed — absence breaks glibc/tools silently.
REQUIRED_ALLOW = [
    # Bash job control / glibc thread init
    "getpgid", "rseq",
    # Modern process management
    "pidfd_open", "pidfd_send_signal", "pidfd_getfd", "close_range",
    # mkfifo / named pipes (gitstatusd)
    "mknod", "mknodat",
    # xattr family — apt/tar silently fail without these
    "getxattr", "setxattr",
    "lgetxattr", "fgetxattr",
    "lsetxattr", "fsetxattr",
    "removexattr", "lremovexattr", "fremovexattr",
    "listxattr", "llistxattr", "flistxattr",
]

# Syscalls that MUST return a SPECIFIC errno (not just "deny").
# clone3 → ENOSYS=38 is load-bearing for glibc fallback to clone(); EPERM
# silently breaks threading.
REQUIRED_ERRNO = {
    "clone3": 38,
}


def _check(name, ok, **details):
    return {
        "section": "seccomp_static",
        "name": name,
        "verdict": "OK" if ok else "DRIFT",
        "details": details,
    }


def run():
    out = []

    if not os.path.isfile(SECCOMP_PATH):
        return [{
            "section": "seccomp_static",
            "name": "seccomp_json_present",
            "verdict": "UNKNOWN",
            "details": {
                "error": f"missing: {SECCOMP_PATH}",
                "hint": "stage the audit package first",
            },
        }]

    try:
        j = json.load(open(SECCOMP_PATH))
    except Exception as e:
        return [{
            "section": "seccomp_static",
            "name": "seccomp_json_parse",
            "verdict": "UNKNOWN",
            "details": {"error": f"{type(e).__name__}: {e}"},
        }]

    # Default action — deny by default.
    default = j.get("defaultAction", "")
    out.append(_check(
        "default_action",
        default == "SCMP_ACT_ERRNO",
        expected="SCMP_ACT_ERRNO",
        observed=default,
    ))

    # Build name -> [(action, errno, args), ...] index.
    rules = {}
    for r in j.get("syscalls", []):
        for n in r.get("names", []):
            rules.setdefault(n, []).append((
                r.get("action"),
                r.get("errnoRet"),
                r.get("args"),
            ))

    # Required allows.
    missing_allow = []
    for n in REQUIRED_ALLOW:
        actions = [a[0] for a in rules.get(n, [])]
        if not any(a == "SCMP_ACT_ALLOW" for a in actions):
            missing_allow.append({"syscall": n, "actions": actions})
    out.append(_check(
        "required_allow",
        not missing_allow,
        missing_or_wrong=missing_allow,
        checked_count=len(REQUIRED_ALLOW),
    ))

    # Required specific errnos.
    errno_drift = []
    for n, expected_errno in REQUIRED_ERRNO.items():
        hits = rules.get(n, [])
        ok = any(
            a == "SCMP_ACT_ERRNO" and e == expected_errno
            for a, e, _ in hits
        )
        if not ok:
            errno_drift.append({
                "syscall": n,
                "expected_errno": expected_errno,
                "observed": hits,
            })
    out.append(_check(
        "required_errno",
        not errno_drift,
        drift=errno_drift,
        rationale="clone3 → ENOSYS=38 is load-bearing for glibc fallback",
    ))

    # Block count + total allowed syscalls (informational).
    total_allow = sum(
        len(r.get("names", []))
        for r in j.get("syscalls", [])
        if r.get("action") == "SCMP_ACT_ALLOW"
    )
    out.append({
        "section": "seccomp_static",
        "name": "rule_blocks",
        "verdict": "INFO",
        "details": {
            "block_count": len(j.get("syscalls", [])),
            "total_allowed_syscalls": total_allow,
            "default_action": default,
        },
    })

    return out


if __name__ == "__main__":
    import sys
    json.dump(run(), sys.stdout, indent=2)
    print()
