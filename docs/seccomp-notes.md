# seccomp notes

Filter lives at `seccomp.json` (applied at runtime via `security_opt: seccomp=./seccomp.json` — changes take effect on `--force-recreate`, no rebuild).

## Syscalls that must stay in the allowlist

| Syscall | Needed by | Symptom if missing |
|---|---|---|
| `getpgid` | bash job control (glibc `getpgrp()` → `getpgid` syscall) | `bash: initialize_job_control: getpgrp failed: Operation not permitted` |
| `rseq` | glibc thread init | random silent stalls in multithreaded binaries |
| `pidfd_open`, `pidfd_send_signal`, `pidfd_getfd` | modern process mgmt | node/zsh subprocess errors |
| `close_range` | Go/C++ runtimes closing inherited FDs | process startup errors |
| `mknod`, `mknodat` | mkfifo (named pipes) for gitstatusd | p10k "gitstatus failed to initialize" |
| xattr family (`getxattr`, `setxattr`, `lgetxattr`, `fgetxattr`, `removexattr`, `listxattr`, and `l*`/`f*` variants) | tar extraction, apt | silent failures |

## `clone3` must return ENOSYS (38), not EPERM

`clone3` takes a struct-pointer arg that seccomp can't inspect, so we can't enforce `!CLONE_NEWUSER` on it. Return `ENOSYS` so glibc falls back to `clone()` (which IS filtered). Any other errno → glibc won't fall back, threading breaks.

## Editing rule

New seccomp allowance? Document the syscall and why in the comment above the `names` array.
