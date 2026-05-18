"""Identity, privileges, SUID inventory, plus MAC.

Stdlib only. Self-targeted reads of /proc and a single `find` for SUID.

windows-ai-sandbox: container runs as ROOT (UID 0) under rootless Docker
userns=host. Container UID 0 maps to host UID 1000 via the userns map, so
in-container `id` returns 0 but the host kernel sees an unprivileged user.
This is the documented invariant — see CLAUDE.md."""
import os
import stat
import subprocess

# The stock Ubuntu 24.04 SUID/SGID set baked into the base image. Anything
# outside this set is drift.
EXPECTED_SUID = {
    "chage", "chfn", "chsh", "expiry", "gpasswd", "mount", "newgrp",
    "pam_extrausers_chkpwd", "passwd", "su", "umount", "unix_chkpwd",
}


def _proc_status():
    fields = {}
    try:
        with open("/proc/self/status") as f:
            for line in f:
                if ":" in line:
                    k, v = line.split(":", 1)
                    fields[k.strip()] = v.strip()
    except OSError:
        pass
    return fields


def _which(cmd):
    for d in os.environ.get("PATH", "").split(":"):
        p = os.path.join(d, cmd)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return ""


def _check(section, name, ok, **details):
    return {
        "section": section,
        "name": name,
        "verdict": "OK" if ok else "DRIFT",
        "details": details,
    }


def _read_uid_map():
    """Return list of (in_ns, host, count) tuples from /proc/self/uid_map."""
    try:
        with open("/proc/self/uid_map") as f:
            entries = []
            for line in f:
                parts = line.split()
                if len(parts) == 3:
                    entries.append(tuple(int(p) for p in parts))
            return entries
    except OSError:
        return []


def run():
    out = []
    s = _proc_status()

    # uid / gid — agent container runs as 0:0 (root-in-container under rootless
    # userns=host). The userns map below confirms host UID 1000, not real root.
    uid, gid = os.getuid(), os.getgid()
    out.append(_check("identity", "uid", uid == 0, expected=0, observed=uid))
    out.append(_check("identity", "gid", gid == 0, expected=0, observed=gid))

    # uid_map line 1 must be "0 1000 1" — container UID 0 → host UID 1000.
    # If it's "0 0 1" we'd be under rootful Docker (catastrophic).
    umap = _read_uid_map()
    line1_ok = bool(umap) and umap[0] == (0, 1000, 1)
    out.append(_check(
        "identity", "userns_root_to_host_1000",
        line1_ok,
        expected="(0, 1000, 1)",
        observed=str(umap[0]) if umap else "(empty)",
        full_map=str(umap),
        rationale="rootless Docker invariant: container root must map to host UID 1000",
    ))

    # CapEff/Prm/Inh/Bnd/Amb all zero — cap_drop: ALL.
    cap_eff = s.get("CapEff", "")
    out.append(_check(
        "identity", "capabilities",
        cap_eff == "0000000000000000",
        expected="0000000000000000",
        observed=cap_eff,
    ))

    # NoNewPrivs — SUID neutralization.
    nnp = s.get("NoNewPrivs", "")
    out.append(_check(
        "identity", "no_new_privs",
        nnp == "1",
        expected="1", observed=nnp,
    ))

    # Seccomp mode 2 (filter active).
    seccomp_mode = (s.get("Seccomp", "").split() or [""])[0]
    out.append(_check(
        "identity", "seccomp_mode",
        seccomp_mode == "2",
        expected="2", observed=seccomp_mode,
    ))

    # sudo — must be absent.
    sudo = _which("sudo")
    out.append(_check(
        "identity", "sudo_absent",
        not sudo,
        expected="(absent)", observed=sudo or "(absent)",
    ))

    # SUID/SGID inventory — drift = something outside the stock set.
    try:
        result = subprocess.run(
            ["find", "/", "-xdev", "-perm", "/6000", "-type", "f"],
            capture_output=True, text=True, timeout=30,
        )
        actual = {os.path.basename(p) for p in result.stdout.splitlines() if p}
        unexpected = sorted(actual - EXPECTED_SUID)
        missing = sorted(EXPECTED_SUID - actual)
        out.append({
            "section": "identity",
            "name": "suid_inventory",
            "verdict": "OK" if (not unexpected and not missing) else "DRIFT",
            "details": {
                "expected": sorted(EXPECTED_SUID),
                "observed": sorted(actual),
                "unexpected": unexpected,
                "missing": missing,
            },
        })
    except Exception as e:
        out.append({
            "section": "identity",
            "name": "suid_inventory",
            "verdict": "UNKNOWN",
            "details": {"error": f"{type(e).__name__}: {e}"},
        })

    # MAC — AppArmor profile. Under rootless Docker on WSL2 the docker-default
    # profile may not be applied (WSL2 kernel sometimes lacks AppArmor LSM).
    # WEAK when absent; not DRIFT.
    apparmor = ""
    try:
        with open("/proc/self/attr/current") as f:
            apparmor = f.read().strip()
    except OSError:
        pass
    selinux_present = os.path.isdir("/sys/fs/selinux")
    apparmor_ok = "docker-default" in apparmor and "(enforce)" in apparmor
    out.append({
        "section": "mac",
        "name": "apparmor_profile",
        "verdict": "OK" if apparmor_ok else "WEAK",
        "details": {
            "observed": apparmor,
            "selinux_present": selinux_present,
            "rationale": ("AppArmor may not apply under rootless Docker on WSL2; "
                          "seccomp + cap_drop + userns remain the boundary"),
        },
    })

    return out


if __name__ == "__main__":
    import json
    import sys
    json.dump(run(), sys.stdout, indent=2)
    print()
