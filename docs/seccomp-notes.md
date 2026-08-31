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
| `creat` | GNU tar CREATING an archive file (`tar -cf x.tar …`); legacy alias for `open(O_CREAT\|O_WRONLY\|O_TRUNC)` | `tar: x.tar: Cannot open: Operation not permitted` — and under `cap_drop: ALL` that reads as a capability problem, which is what made it expensive to find (work/0017) |

## `clone3` must return ENOSYS (38), not EPERM

`clone3` takes a struct-pointer arg that seccomp can't inspect, so we can't enforce `!CLONE_NEWUSER` on it. Return `ENOSYS` so glibc falls back to `clone()` (which IS filtered). Any other errno → glibc won't fall back, threading breaks.

## Behavioural probes beat reading this file

There is no test suite for `seccomp.json`, and a syscall missing from an
allowlist is invisible until something breaks at the point of use — `creat` was
absent from the first version of this profile and surfaced only when somebody
finally ran `tar -cf`, as "tar is broken". `verify` now
runs `tar -cf <file>` inside the container for that reason. Grepping the JSON on
the host would not do: it says nothing about the profile a RUNNING container was
started with, and seccomp changes need a recreate.

## Editing rule

New seccomp allowance? Document the syscall and why in the comment above the `names` array.
