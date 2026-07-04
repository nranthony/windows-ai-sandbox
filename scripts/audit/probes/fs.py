"""Filesystem invariants, /proc & /sys exposure, PIDs, devices, cgroups.

windows-ai-sandbox: paths are /root/ (container runs as root). WSL2 bind
mounts are ext4 by default — no virtiofs gotchas. /dev/dxg is expected
(WSL2 GPU device); /usr/lib/wsl is bind-mounted for the driver shim."""
import json
import os
import stat
import subprocess


def _check(section, name, ok, **details):
    return {
        "section": section,
        "name": name,
        "verdict": "OK" if ok else "DRIFT",
        "details": details,
    }


def _findmnt(target):
    """Return findmnt -no SOURCE,FSTYPE,OPTIONS for `target`, or None."""
    try:
        r = subprocess.run(
            ["findmnt", "-no", "SOURCE,FSTYPE,OPTIONS", target],
            capture_output=True, text=True, timeout=5,
        )
        if r.returncode != 0:
            return None
        parts = r.stdout.strip().split(maxsplit=2)
        return {
            "source":  parts[0] if len(parts) > 0 else "",
            "fstype":  parts[1] if len(parts) > 1 else "",
            "options": parts[2] if len(parts) > 2 else "",
        }
    except Exception:
        return None


def _stat_file(path):
    try:
        st = os.stat(path)
        return {
            "mode": stat.S_IMODE(st.st_mode),
            "uid":  st.st_uid,
            "gid":  st.st_gid,
            "size": st.st_size,
        }
    except OSError as e:
        return {"error": f"{type(e).__name__}: {e}"}


def run():
    out = []

    # ~/.claude.json — single-file bind, owned by root (UID 0) in-container.
    info = _stat_file("/root/.claude.json")
    ok = (info.get("uid") == 0
          and info.get("gid") == 0)
    if ok and "error" not in info:
        try:
            json.load(open("/root/.claude.json"))
        except Exception as e:
            ok = False
            info["json_parse_error"] = f"{type(e).__name__}: {e}"
    out.append(_check(
        "fs", "claude_json", ok,
        expected="uid=0 gid=0 valid-json",
        **info,
    ))

    # ~/.claude/.credentials.json — mode 600.
    cred = "/root/.claude/.credentials.json"
    if os.path.exists(cred):
        info = _stat_file(cred)
        ok = info.get("mode") == 0o600
        out.append(_check("fs", "credentials_json", ok, expected="mode=600", **info))
    else:
        out.append({
            "section": "fs",
            "name": "credentials_json",
            "verdict": "N/A",
            "details": {"note": "not present (no Claude login on this profile)"},
        })

    # ~/.gitconfig MUST NOT exist (use GIT_CONFIG_GLOBAL → .config/git/config).
    gitcfg_present = os.path.exists("/root/.gitconfig")
    out.append(_check(
        "fs", "no_gitconfig_bindmount", not gitcfg_present,
        expected="absent",
        observed="present" if gitcfg_present else "absent",
    ))
    git_config_global = os.environ.get("GIT_CONFIG_GLOBAL", "")
    out.append(_check(
        "fs", "git_config_global_env",
        git_config_global == "/root/.config/git/config",
        expected="/root/.config/git/config",
        observed=git_config_global or "(unset)",
    ))

    # /tmp — system tmpfs, noexec.
    m = _findmnt("/tmp")
    if m:
        opts = m["options"].split(",")
        ok = m["fstype"] == "tmpfs" and "noexec" in opts
        out.append(_check(
            "fs", "tmp_tmpfs_noexec", ok,
            expected="tmpfs with noexec",
            **m,
        ))

    # /proc/kcore MUST be masked (Docker default — char dev or EACCES on read).
    try:
        st = os.stat("/proc/kcore")
        masked = stat.S_ISCHR(st.st_mode)
        out.append(_check(
            "fs", "proc_kcore_masked", masked,
            expected="character device (masked)",
            mode_octal=oct(st.st_mode),
        ))
    except OSError as e:
        out.append({
            "section": "fs",
            "name": "proc_kcore_masked",
            "verdict": "UNKNOWN",
            "details": {"error": str(e)},
        })

    # /sys/firmware MUST be empty (Docker MaskedPaths).
    try:
        contents = os.listdir("/sys/firmware")
        out.append(_check(
            "fs", "sys_firmware_masked", not contents,
            expected="empty",
            observed_count=len(contents),
        ))
    except OSError as e:
        out.append({
            "section": "fs",
            "name": "sys_firmware_masked",
            "verdict": "UNKNOWN",
            "details": {"error": str(e)},
        })

    # /dev — host devices MUST NOT be passed through. WSL2 GPU adds /dev/dxg.
    expected_dev = {
        "null", "full", "random", "urandom", "zero", "tty", "ptmx",
        "console", "stdin", "stdout", "stderr", "fd", "core",
        "pts", "shm", "mqueue",
        # WSL2 GPU passthrough (required for CUDA).
        "dxg",
    }
    try:
        actual_dev = set(os.listdir("/dev/"))
        unexpected = sorted(actual_dev - expected_dev)
        out.append({
            "section": "fs",
            "name": "dev_inventory",
            "verdict": "OK" if not unexpected else "DRIFT",
            "details": {
                "expected": sorted(expected_dev),
                "observed": sorted(actual_dev),
                "unexpected": unexpected,
                "rationale": "/dev/dxg is the WSL2 GPU device; other entries are drift",
            },
        })
    except OSError as e:
        out.append({
            "section": "fs",
            "name": "dev_inventory",
            "verdict": "UNKNOWN",
            "details": {"error": str(e)},
        })

    # /usr/lib/wsl — driver shim for CUDA passthrough (informational).
    # Substrate-aware: the shim arrives via the wsl-gpu compose overlay, which
    # profile.sh only layers when /dev/dxg exists. No dxg + no shim = bare-Linux
    # arm, N/A. dxg without the shim = overlay drift, WEAK.
    wsl_lib = os.path.isdir("/usr/lib/wsl/lib")
    has_dxg = os.path.exists("/dev/dxg")
    out.append({
        "section": "fs",
        "name": "wsl_driver_shim",
        "verdict": "OK" if wsl_lib else ("WEAK" if has_dxg else "N/A"),
        "details": {
            "path": "/usr/lib/wsl/lib",
            "present": wsl_lib,
            "dxg_present": has_dxg,
            "rationale": "required for CUDA via /dev/dxg; absence breaks GPU but not security; N/A when the host has no /dev/dxg (bare Linux — wsl-gpu overlay not layered)",
        },
    })

    # cgroups v2 unified hierarchy, mounted read-only.
    m = _findmnt("/sys/fs/cgroup")
    if m:
        opts = m["options"].split(",")
        ok = m["fstype"] == "cgroup2" and "ro" in opts
        out.append(_check(
            "fs", "cgroups_v2_readonly", ok,
            expected="cgroup2 ro",
            **m,
        ))

    # pids.max — set to a reasonable bound, not "max".
    try:
        with open("/sys/fs/cgroup/pids.max") as f:
            pm = f.read().strip()
        out.append({
            "section": "fs",
            "name": "pids_max",
            "verdict": "OK" if pm not in ("max", "") else "WEAK",
            "details": {"observed": pm},
        })
    except OSError as e:
        out.append({
            "section": "fs",
            "name": "pids_max",
            "verdict": "UNKNOWN",
            "details": {"error": str(e)},
        })

    # PID namespace — total visible PIDs and any non-PID-1 process besides root.
    # Under root-in-container all processes are UID 0, so the orphan check from
    # macolima doesn't apply directly. We instead just record the count.
    try:
        result = subprocess.run(
            ["ps", "-eo", "pid,user", "--no-headers"],
            capture_output=True, text=True, timeout=5,
        )
        pids = []
        for line in result.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 2:
                pids.append(parts[0])
        out.append({
            "section": "fs",
            "name": "pid_namespace",
            "verdict": "OK",
            "details": {
                "total_pids": len(pids),
                "pid1_present": "1" in pids,
            },
        })
    except Exception as e:
        out.append({
            "section": "fs",
            "name": "pid_namespace",
            "verdict": "UNKNOWN",
            "details": {"error": str(e)},
        })

    return out


if __name__ == "__main__":
    import sys
    json.dump(run(), sys.stdout, indent=2)
    print()
