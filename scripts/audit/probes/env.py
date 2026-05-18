"""Secrets hygiene — env scan + VS Code Dev Containers leakage checks.

Most VS Code leakage controls live host-side (devcontainer.json, host VS Code
settings); this probe checks the in-container reality: env unset, no socket
remnant, no host gitconfig, no host-reaching credential.helper.

windows-ai-sandbox: paths are /root/ (container runs as root)."""
import glob
import os
import re
import shutil

CRED_PATTERNS = [
    re.compile(r".*(_TOKEN|_KEY|_SECRET|_PASSWORD|_PASS|_API_KEY)$",
               re.IGNORECASE),
]

# Host-reaching credential helpers — VS Code IPC shim or Windows host helpers
# (git-credential-manager often comes via Git for Windows on the host).
# Benign in-container helpers (gh / glab) are NOT in this set.
HOST_REACHING_HELPER = re.compile(
    r"helper\s*=.*(vscode-server|vscode-remote-containers|"
    r"git-credential-manager)"
)


def _check(name, ok, **details):
    return {
        "section": "env",
        "name": name,
        "verdict": "OK" if ok else "DRIFT",
        "details": details,
    }


def run():
    out = []

    # SSH_AUTH_SOCK MUST be unset. Host fix:
    # `remote.SSH.enableAgentForwarding: false` in VS Code settings.
    val = os.environ.get("SSH_AUTH_SOCK", "")
    out.append(_check(
        "ssh_auth_sock_unset",
        not val,
        observed=val or "(unset)",
    ))

    # No /tmp/vscode-ssh-auth-*.sock — VS Code's attach helper creates these.
    # The env blank closes the env-level path; the file remnant is cosmetic
    # so long as `openssh-client` is purged (no `ssh`/`scp`/`ssh-add` to
    # consume the socket). DRIFT only when *either* mitigation has failed.
    socks = glob.glob("/tmp/vscode-ssh-auth-*.sock")
    env_unset = not val
    ssh_purged = shutil.which("ssh") is None
    sock_ok = (not socks) or (env_unset and ssh_purged)
    out.append(_check(
        "no_vscode_ssh_socket",
        sock_ok,
        found_count=len(socks),
        files=socks[:5],
        env_unset=env_unset,
        ssh_purged=ssh_purged,
        rationale=("socket file is cosmetic when SSH_AUTH_SOCK is unset AND "
                   "openssh-client is purged; DRIFT only if either layer fails"),
    ))

    # No host .gitconfig in rootfs overlay. Host fix:
    # `dev.containers.copyGitConfig: false` in user-level VS Code settings.
    gitcfg = os.path.exists("/root/.gitconfig")
    out.append(_check(
        "no_host_gitconfig",
        not gitcfg,
        observed="present" if gitcfg else "absent",
    ))

    # No host-reaching credential.helper in .config/git/config. Benign
    # in-container helpers (`!/usr/local/bin/gh auth git-credential` etc.) pass.
    git_cfg_path = "/root/.config/git/config"
    host_reaching = []
    if os.path.isfile(git_cfg_path):
        try:
            with open(git_cfg_path) as f:
                for i, line in enumerate(f, 1):
                    if HOST_REACHING_HELPER.search(line):
                        host_reaching.append({
                            "line_no": i,
                            "line": line.strip(),
                        })
        except OSError:
            pass
    out.append(_check(
        "no_host_reaching_credential_helper",
        not host_reaching,
        found=host_reaching,
        rationale=("benign gh/glab helpers OK; flag only "
                   "vscode-server | vscode-remote-containers | "
                   "git-credential-manager"),
    ))

    # Env scan — credential-shaped keys (names only, no values).
    cred_named = []
    for k in os.environ:
        for p in CRED_PATTERNS:
            if p.match(k):
                cred_named.append(k)
                break
    out.append({
        "section": "env",
        "name": "env_credential_named_keys",
        "verdict": "INFO",
        "details": {
            "keys": sorted(cred_named),
            "rationale": ("named keys may be project DSNs / DB env / API "
                          "keys; values redacted in this layer"),
        },
    })

    # GIT_ASKPASS / VSCODE_GIT_ASKPASS_* — informational. Host-reaching prompt
    # path; dormant under autonomous-mode `git push|clone|fetch|pull` denies,
    # active in planning mode.
    askpass_keys = ("GIT_ASKPASS", "VSCODE_GIT_ASKPASS_NODE",
                    "VSCODE_GIT_ASKPASS_MAIN", "VSCODE_GIT_IPC_HANDLE")
    askpass = {k: bool(os.environ.get(k)) for k in askpass_keys}
    out.append({
        "section": "env",
        "name": "vscode_git_askpass_present",
        "verdict": "INFO",
        "details": askpass,
    })

    return out


if __name__ == "__main__":
    import json
    import sys
    json.dump(run(), sys.stdout, indent=2)
    print()
