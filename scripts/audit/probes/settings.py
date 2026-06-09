"""Claude Code settings audit.

- Live settings.json present + parses.
- sandbox.enabled = false (Claude Code's bwrap is correctly disabled).
- No bare WebFetch in user-level allow.
- All required deny categories present.
- Live vs. template diff (excluding documented user-customization keys).
- Per-project settings.local.json walk for bare/wildcard WebFetch.
- PreToolUse hook wiring + on-disk hook script invariants.

windows-ai-sandbox: container runs as root (UID 0). The kernel-write-protect
that macolima relies on for the hook script does NOT apply here — the agent
IS root. `hook_file_immutable` therefore emits WEAK + rationale, not DRIFT,
when the file is writable. Image rebuild restores the canonical script."""
import json
import os
import subprocess

LIVE = "/root/.claude/settings.json"
TEMPLATE = "/workspace/temp_audit_package/config/claude-settings.json"
HOOK_PATH = "/usr/local/lib/claude-hooks/deny-destructive.sh"

REQUIRED_HOOKS = [
    {"matcher": "Bash",                 "command_endswith": "deny-destructive.sh"},
    {"matcher": "Edit|Write|MultiEdit", "command_endswith": "deny-destructive.sh"},
]

# Documented user-customization fields seeded after first `up` and intentionally
# not template-mirrored. Strip before diffing.
USER_CUSTOMIZATION_KEYS = {"theme", "model", "effortLevel"}


def _strip_doc_keys(obj):
    """Recursively drop keys beginning with '_' (e.g. the template's '_comment'
    inside `hooks`). JSON has no comment syntax, so '_'-prefixed keys are the
    convention used to annotate the template for humans; they are never deployed
    to the live settings and must not register as template drift."""
    if isinstance(obj, dict):
        return {k: _strip_doc_keys(v) for k, v in obj.items()
                if not k.startswith("_")}
    if isinstance(obj, list):
        return [_strip_doc_keys(v) for v in obj]
    return obj

# Required permissions.deny set.
REQUIRED_DENY = {
    "network": [
        "Bash(curl:*)", "Bash(wget:*)", "Bash(socat:*)", "Bash(nc:*)",
        "Bash(ncat:*)", "Bash(netcat:*)", "Bash(telnet:*)",
        "Bash(ssh:*)", "Bash(scp:*)", "Bash(sftp:*)", "Bash(rsync:*)",
    ],
    "vcs": [
        "Bash(git push:*)", "Bash(git clone:*)", "Bash(git fetch:*)",
        "Bash(git pull:*)", "Bash(gh:*)", "Bash(glab:*)",
    ],
    "installers": [
        "Bash(npm install:*)", "Bash(npm ci:*)", "Bash(npx:*)",
        "Bash(pip install:*)", "Bash(pip3 install:*)",
        "Bash(python -m pip:*)", "Bash(python3 -m pip:*)",
        "Bash(uv add:*)", "Bash(uv pip install:*)",
        "Bash(uv tool install:*)", "Bash(uvx:*)", "Bash(pipx:*)",
        "Bash(cargo install:*)", "Bash(go install:*)", "Bash(go get:*)",
    ],
    "shell_escape": [
        "Bash(bash -c:*)", "Bash(sh -c:*)", "Bash(zsh -c:*)",
        "Bash(uv run bash:*)", "Bash(uv run sh:*)", "Bash(uv run zsh:*)",
        "Bash(python -c:*)", "Bash(python3 -c:*)", "Bash(node -e:*)",
        "Bash(perl -e:*)", "Bash(perl:*)", "Bash(ruby:*)", "Bash(lua:*)",
        "Bash(env:*)", "Bash(xargs:*)", "Bash(eval:*)",
    ],
    "destructive": [
        "Bash(rm -rf:*)", "Bash(git reset --hard:*)", "Bash(git rebase:*)",
    ],
    "system": [
        "Bash(docker:*)", "Bash(sudo:*)", "Bash(mount:*)", "Bash(umount:*)",
    ],
    "read_patterns": [
        "Read(**/.env)", "Read(**/.env.*)",
        "Read(**/*.pem)", "Read(**/*.key)",
        "Read(**/.credentials*)",
        "Read(**/id_rsa*)", "Read(**/id_ed25519*)",
    ],
}


def _check(name, ok, **details):
    return {
        "section": "settings",
        "name": name,
        "verdict": "OK" if ok else "DRIFT",
        "details": details,
    }


def run():
    out = []

    if not os.path.isfile(LIVE):
        return [{
            "section": "settings",
            "name": "live_settings_present",
            "verdict": "DRIFT",
            "details": {"error": f"missing: {LIVE}"},
        }]
    try:
        live = json.load(open(LIVE))
    except Exception as e:
        return [{
            "section": "settings",
            "name": "live_settings_parse",
            "verdict": "DRIFT",
            "details": {"error": f"{type(e).__name__}: {e}"},
        }]

    # sandbox.enabled = false — bwrap can't run inside (seccomp blocks userns).
    sandbox_enabled = (live.get("sandbox", {}).get("enabled") is True)
    out.append(_check(
        "sandbox_enabled_false",
        not sandbox_enabled,
        observed=live.get("sandbox", {}).get("enabled"),
        rationale="Claude Code bwrap is disabled by design; container is the boundary",
    ))

    # No bare WebFetch / WebFetch(*) in user-level allow.
    user_allow = live.get("permissions", {}).get("allow", [])
    bare_or_wild = [
        e for e in user_allow
        if e == "WebFetch" or e == "WebFetch(*)" or
           (e.startswith("WebFetch") and not e.startswith("WebFetch(domain:"))
    ]
    out.append(_check(
        "no_bare_webfetch_user",
        not bare_or_wild,
        found=bare_or_wild,
        rationale=("WebFetch runs server-side on Anthropic infra; bare entry "
                   "is a covert exfil channel since destination logs full URL"),
    ))

    # Required deny categories.
    user_deny = set(live.get("permissions", {}).get("deny", []))
    deny_drift = {}
    for category, expected in REQUIRED_DENY.items():
        missing = [e for e in expected if e not in user_deny]
        if missing:
            deny_drift[category] = missing
    out.append(_check(
        "required_deny_categories",
        not deny_drift,
        drift=deny_drift,
        checked_count=sum(len(v) for v in REQUIRED_DENY.values()),
    ))

    # Live vs. template diff.
    if os.path.isfile(TEMPLATE):
        try:
            template = _strip_doc_keys(json.load(open(TEMPLATE)))
            live_filtered = _strip_doc_keys({
                k: v for k, v in live.items()
                if k not in USER_CUSTOMIZATION_KEYS
            })
            ok = (json.dumps(live_filtered, sort_keys=True) ==
                  json.dumps(template, sort_keys=True))
            details = {"identical_after_strip": ok,
                       "stripped_keys": sorted(USER_CUSTOMIZATION_KEYS),
                       "doc_keys_ignored": "'_'-prefixed (e.g. _comment)"}
            if not ok:
                diff_keys = set()
                for k in set(live_filtered.keys()) | set(template.keys()):
                    if live_filtered.get(k) != template.get(k):
                        diff_keys.add(k)
                details["differing_top_level_keys"] = sorted(diff_keys)
            out.append(_check("template_diff", ok, **details))
        except Exception as e:
            out.append({
                "section": "settings",
                "name": "template_diff",
                "verdict": "UNKNOWN",
                "details": {"error": f"{type(e).__name__}: {e}"},
            })
    else:
        out.append({
            "section": "settings",
            "name": "template_diff",
            "verdict": "UNKNOWN",
            "details": {"error": f"missing: {TEMPLATE}"},
        })

    # Per-project settings.local.json walk for WebFetch policy.
    try:
        result = subprocess.run(
            ["find", "/workspace", "-name", "settings.local.json",
             "-path", "*/.claude/*",
             "-not", "-path", "*/temp_audit_package/*"],
            capture_output=True, text=True, timeout=10,
        )
        project_files = [p for p in result.stdout.splitlines() if p]
    except Exception:
        project_files = []

    project_drift = []
    project_summary = []
    for path in project_files:
        try:
            j = json.load(open(path))
        except Exception as e:
            project_drift.append({
                "file": path,
                "error": f"{type(e).__name__}: {e}",
            })
            continue
        allow = j.get("permissions", {}).get("allow", [])
        bare = [
            e for e in allow
            if e == "WebFetch" or e == "WebFetch(*)" or
               (e.startswith("WebFetch") and not e.startswith("WebFetch(domain:"))
        ]
        scoped = [e for e in allow if e.startswith("WebFetch(domain:")]
        if bare:
            project_drift.append({"file": path, "bare_or_wildcard": bare})
        project_summary.append({
            "file": path,
            "scoped_count": len(scoped),
            "scoped_domains": [
                e[len("WebFetch(domain:"):-1] for e in scoped
            ],
        })
    out.append(_check(
        "per_project_webfetch_scoped",
        not project_drift,
        drift=project_drift,
        summary=project_summary,
    ))

    # PreToolUse hooks: matcher wiring + on-disk file invariants.
    out.extend(_check_hooks(live))

    return out


def _check_hooks(live):
    """deny-destructive PreToolUse hook checks.

    Two surfaces:
      1. settings.json wires both matchers to the in-image hook (DRIFT if not).
      2. The hook file is in-image, executable. Under root-in-container we
         cannot rely on kernel write-protect; agent CAN write to the script.
         Mark as WEAK (not DRIFT) when the file is writable — the matcher
         and tamper rules are the only enforcement layer, and image rebuild
         restores the canonical script."""
    out = []
    hooks_cfg = (live or {}).get("hooks", {}).get("PreToolUse", []) or []
    for req in REQUIRED_HOOKS:
        present = any(
            entry.get("matcher") == req["matcher"]
            and any(h.get("command", "").endswith(req["command_endswith"])
                    for h in entry.get("hooks", []))
            for entry in hooks_cfg
        )
        out.append(_check(
            f"hook_present_{req['matcher'].replace('|','_')}",
            present,
            required=req,
        ))

    try:
        st = os.stat(HOOK_PATH)
        exists = True
        executable = bool(st.st_mode & 0o111)
        owner_uid = st.st_uid
        agent_writable = os.access(HOOK_PATH, os.W_OK)
    except FileNotFoundError:
        exists = executable = False
        owner_uid = None
        agent_writable = None

    # hook_present_on_disk: must exist + executable. DRIFT otherwise.
    out.append(_check(
        "hook_present_on_disk",
        exists and executable,
        path=HOOK_PATH, exists=exists, executable=executable,
        owner_uid=owner_uid,
    ))

    # hook_immutable: under root-in-container the agent IS root and can write
    # to the hook. This is the documented trade-off (see docs/deny-destructive-
    # hook-plan.md). Mark WEAK + rationale; not new DRIFT.
    if exists:
        verdict = "WEAK" if agent_writable else "OK"
        out.append({
            "section": "settings",
            "name": "hook_immutable",
            "verdict": verdict,
            "details": {
                "path": HOOK_PATH,
                "agent_writable": agent_writable,
                "rationale": ("agent runs as root in this repo; kernel write-protect "
                              "does not apply. Hook tamper is closed via Bash/Edit "
                              "rules + image rebuild restores canonical script."),
            },
        })
    return out


if __name__ == "__main__":
    import sys
    json.dump(run(), sys.stdout, indent=2)
    print()
