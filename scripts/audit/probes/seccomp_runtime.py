"""seccomp runtime probes via ctypes.

All read-only, self-targeted. Confirms the static config in seccomp.json is
actually enforced at runtime. Uses libc wrappers where they exist (architecture-
neutral); raw syscall() only where there's no wrapper (clone3, pidfd_open,
close_range — these need per-arch syscall numbers).

clone3 has no glibc wrapper — glibc deliberately doesn't expose it (it owns
clone3 itself for fork()). Hence raw syscall() with arch-aware NR.
"""
import ctypes
import ctypes.util
import errno
import os
import platform

CLONE_NEWUSER = 0x10000000

# Per-arch syscall numbers — only needed where there's no libc wrapper.
_NR = {
    "x86_64":  {"clone3": 435, "pidfd_open": 434, "close_range": 436},
    "aarch64": {"clone3": 435, "pidfd_open": 434, "close_range": 436},
}


def _libc():
    return ctypes.CDLL(
        ctypes.util.find_library("c") or "libc.so.6",
        use_errno=True,
    )


def _check(name, ok, **details):
    return {
        "section": "seccomp_runtime",
        "name": name,
        "verdict": "OK" if ok else "DRIFT",
        "details": details,
    }


def _raw_syscall(libc, nr, *args):
    libc.syscall.restype = ctypes.c_long
    ctypes.set_errno(0)
    rv = libc.syscall(ctypes.c_long(nr), *[ctypes.c_long(a) for a in args])
    return rv, ctypes.get_errno()


def run():
    out = []
    libc = _libc()
    arch = platform.machine()
    nr_table = _NR.get(arch, {})

    # unshare(CLONE_NEWUSER) — must EPERM.
    try:
        libc.unshare.argtypes = [ctypes.c_int]
        libc.unshare.restype = ctypes.c_int
        ctypes.set_errno(0)
        rv = libc.unshare(CLONE_NEWUSER)
        e = ctypes.get_errno()
        out.append(_check(
            "unshare_newuser_blocked",
            rv == -1 and e == errno.EPERM,
            expected="rv=-1 errno=1 (EPERM)",
            observed=f"rv={rv} errno={e} ({errno.errorcode.get(e, '?')})",
        ))
    except (AttributeError, OSError) as ex:
        out.append({
            "section": "seccomp_runtime",
            "name": "unshare_newuser_blocked",
            "verdict": "UNKNOWN",
            "details": {
                "error": f"{type(ex).__name__}: {ex}",
                "note": "unshare not available in this libc",
            },
        })

    # clone3(NULL, 0) — MUST be ENOSYS=38, NOT EPERM.
    nr = nr_table.get("clone3")
    if nr is None:
        out.append({
            "section": "seccomp_runtime",
            "name": "clone3_enosys",
            "verdict": "UNKNOWN",
            "details": {"arch": arch, "note": "no clone3 NR table for this arch"},
        })
    else:
        rv, e = _raw_syscall(libc, nr, 0, 0)
        out.append(_check(
            "clone3_enosys",
            rv == -1 and e == errno.ENOSYS,
            expected="rv=-1 errno=38 (ENOSYS)",
            observed=f"rv={rv} errno={e} ({errno.errorcode.get(e, '?')})",
            rationale="EPERM here would silently break threading via glibc fallback",
        ))

    # mkfifo (mknod/mknodat under the hood) — must succeed. gitstatusd needs it.
    fifo = "/tmp/.audit_fifo_probe"
    try:
        try:
            os.unlink(fifo)
        except FileNotFoundError:
            pass
        os.mkfifo(fifo)
        ok = os.path.exists(fifo)
        os.unlink(fifo)
        out.append(_check("mkfifo", ok, fifo=fifo))
    except Exception as ex:
        out.append({
            "section": "seccomp_runtime",
            "name": "mkfifo",
            "verdict": "DRIFT",
            "details": {"error": f"{type(ex).__name__}: {ex}"},
        })

    # getpgid(0) — bash job control.
    try:
        pgid = os.getpgid(0)
        out.append(_check("getpgid", pgid >= 0, observed=f"pgid={pgid}"))
    except OSError as ex:
        out.append(_check(
            "getpgid", False,
            error=f"errno={ex.errno} ({errno.errorcode.get(ex.errno, '?')}): {ex.strerror}",
        ))

    # getxattr — must NOT EPERM/ENOSYS. apt/tar silently fail without.
    try:
        libc.getxattr.argtypes = [
            ctypes.c_char_p, ctypes.c_char_p,
            ctypes.c_void_p, ctypes.c_size_t,
        ]
        libc.getxattr.restype = ctypes.c_long
        buf = ctypes.create_string_buffer(256)
        ctypes.set_errno(0)
        rv = libc.getxattr(b"/", b"user.nonexistent", buf, 256)
        e = ctypes.get_errno()
        out.append(_check(
            "getxattr",
            e not in (errno.EPERM, errno.ENOSYS),
            expected="ENODATA (61) or similar — NOT EPERM/ENOSYS",
            observed=f"rv={rv} errno={e} ({errno.errorcode.get(e, '?')})",
        ))
    except (AttributeError, OSError) as ex:
        out.append({
            "section": "seccomp_runtime",
            "name": "getxattr",
            "verdict": "UNKNOWN",
            "details": {
                "error": f"{type(ex).__name__}: {ex}",
                "note": "getxattr not available",
            },
        })

    # pidfd_open(self) — modern process mgmt; must succeed.
    nr = nr_table.get("pidfd_open")
    if nr is None:
        out.append({
            "section": "seccomp_runtime",
            "name": "pidfd_open",
            "verdict": "UNKNOWN",
            "details": {"arch": arch, "note": "no pidfd_open NR for this arch"},
        })
    else:
        rv, e = _raw_syscall(libc, nr, os.getpid(), 0)
        if rv >= 0:
            os.close(rv)
        out.append(_check(
            "pidfd_open",
            rv >= 0,
            observed=f"rv={rv} errno={e} ({errno.errorcode.get(e, '?')})",
        ))

    # close_range(9999, 9999, 0) — Go/C++ runtime startup; must succeed.
    nr = nr_table.get("close_range")
    if nr is None:
        out.append({
            "section": "seccomp_runtime",
            "name": "close_range",
            "verdict": "UNKNOWN",
            "details": {"arch": arch, "note": "no close_range NR for this arch"},
        })
    else:
        rv, e = _raw_syscall(libc, nr, 9999, 9999, 0)
        out.append(_check(
            "close_range",
            rv == 0,
            observed=f"rv={rv} errno={e} ({errno.errorcode.get(e, '?')})",
        ))

    return out


if __name__ == "__main__":
    import json
    import sys
    json.dump(run(), sys.stdout, indent=2)
    print()
