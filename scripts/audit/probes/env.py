"""Secrets hygiene — env scan + VS Code Dev Containers leakage checks.

Most VS Code leakage controls live host-side (devcontainer.json, host VS Code
settings); this probe checks the in-container reality: env unset, no socket
remnant, no host gitconfig, no host-reaching credential.helper.

windows-ai-sandbox: paths are /root/ (container runs as root)."""
import glob
import os
import re
import shutil
import subprocess

CRED_PATTERNS = [
    re.compile(r".*(_TOKEN|_KEY|_SECRET|_PASSWORD|_PASS|_API_KEY)$",
               re.IGNORECASE),
]

# Host-reaching credential helpers — VS Code IPC shim or host credential
# managers (git-credential-manager via Git for Windows; osxkeychain on macOS,
# kept for macolima parity). Benign in-container helpers (gh / glab) are NOT in
# this set. _HELPER matches a full `helper = ...` config line (file scan);
# _VALUE matches a bare helper value (git --get-all output).
_HOST_REACHING_ALT = (r"vscode-server|vscode-remote-containers|"
                      r"git-credential-manager|osxkeychain")
HOST_REACHING_HELPER = re.compile(r"helper\s*=.*(" + _HOST_REACHING_ALT + ")")
HOST_REACHING_VALUE = re.compile("(" + _HOST_REACHING_ALT + ")")


def _resolved_credential_helpers():
    """`git config --show-origin --get-all credential.helper` across ALL layers
    (system /etc/gitconfig, global $GIT_CONFIG_GLOBAL, repo-local under cwd).
    Returns (rows, ok): rows = [{origin, value}], ok = git ran. This is git's
    own resolution — broader than reading a single file."""
    try:
        p = subprocess.run(
            ["git", "config", "--show-origin", "--get-all",
             "credential.helper"],
            capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return [], False
    rows = []
    for line in p.stdout.splitlines():
        # `--show-origin` emits "origin\tvalue" (origin like "file:/etc/gitconfig")
        origin, _, value = line.partition("\t")
        rows.append({"origin": origin, "value": value})
    return rows, True


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

    # No host-reaching credential.helper across ANY git config layer. Primary:
    # git's resolved config (`--show-origin --get-all`) spans system
    # /etc/gitconfig + global + repo-local — catches injection a single-file
    # grep would miss. Belt: also scan the global file directly, in case
    # GIT_CONFIG_GLOBAL is unset and the injected line is latent (git wouldn't
    # resolve it, but it's still a risk). Benign in-container helpers
    # (`!/usr/local/bin/gh auth git-credential` etc.) pass.
    resolved, git_ok = _resolved_credential_helpers()
    host_reaching = [
        {"source": "resolved", "origin": r["origin"], "value": r["value"]}
        for r in resolved if HOST_REACHING_VALUE.search(r["value"])
    ]
    git_cfg_path = "/root/.config/git/config"
    if os.path.isfile(git_cfg_path):
        try:
            with open(git_cfg_path) as f:
                for i, line in enumerate(f, 1):
                    if HOST_REACHING_HELPER.search(line):
                        host_reaching.append({
                            "source": "global-file",
                            "line_no": i,
                            "line": line.strip(),
                        })
        except OSError:
            pass
    out.append(_check(
        "no_host_reaching_credential_helper",
        not host_reaching,
        found=host_reaching,
        resolved_origins=[r["origin"] for r in resolved],
        git_resolution_ok=git_ok,
        rationale=("resolved via `git config --show-origin --get-all "
                   "credential.helper` (system/global/local) + global-file "
                   "belt; benign gh/glab helpers OK; flag vscode-server | "
                   "vscode-remote-containers | git-credential-manager | "
                   "osxkeychain"),
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
