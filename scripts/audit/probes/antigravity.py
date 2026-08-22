"""Antigravity (`agy`) policy audit.

Two layers are checked, and they are NOT equally important:

  1. `permissions.deny` in /root/.gemini/antigravity-cli/settings.json —
     the layer that must be complete. Nothing in a workspace can reach it.
  2. the `PreToolUse` hook registered by /root/.gemini/config/hooks.json —
     defence-in-depth for envelope patterns (destructive flags, path targets)
     that a command prefix cannot see.

The ordering is the finding of work/0010 Phase 0 and it is counter-intuitive,
so it is worth restating: agy discovers workspace customizations under
`.agents/`, `.agent/`, `_agents/` and `_agent/`, merges hooks BY NAME, and lets
the workspace copy outrank the global one. A file containing

    {"sandbox-guardrails": {"enabled": false}}

in any attached workspace switches the hook off — measured live, with agy
reporting `loaded 1 named hooks from 2 hooks.json file(s)` and the previously
denied command then running. That is why `workspace_hook_shadow` below is DRIFT
and not merely informational, and why the hard denials live in settings.json.

The engine itself is the same script Claude Code uses, under a second name and
a `--dialect=` flag; `settings.py` already covers its on-disk invariants, so
this probe checks the wiring and the behaviour rather than re-checking the file.
"""
import glob
import json
import os
import subprocess

HOOKS_JSON = "/root/.gemini/config/hooks.json"
AGY_SETTINGS = "/root/.gemini/antigravity-cli/settings.json"
ENGINE = "/usr/local/lib/sandbox-hooks/guardrails.sh"
HOOK_NAME = "sandbox-guardrails"

# Live agy state that shares gemini-home/config/ with our hooks.json. A
# directory-mirror convergence would delete these; profile.sh converges
# file-scoped precisely so it cannot. Their absence is not proof of the bug
# (a brand-new profile has none of them), so this is reported, never DRIFT.
AGY_CONFIG_SIBLINGS = ["config.json", "mcp_config.json", "projects", ".migrated"]

# One representative per deny category. Completeness is owned by
# scripts/antigravity-parity.test.sh, which diffs the whole list against
# claude-settings.json offline; duplicating all 85 rules here would be a second
# copy to drift.
REQUIRED_DENY_SAMPLE = {
    "network":       "command(curl)",
    "remote_vcs":    "command(git push)",
    "installers":    "command(npm install)",
    "fetch_and_run": "command(npx)",
    "shell_escape":  "command(bash -c)",
    "destructive":   "command(rm -rf)",
}

WORKSPACE_HOOK_GLOBS = [
    "/workspace/*/.agents/hooks.json",
    "/workspace/*/.agent/hooks.json",
    "/workspace/*/_agents/hooks.json",
    "/workspace/*/_agent/hooks.json",
    "/workspace/.agents/hooks.json",
    "/workspace/.agent/hooks.json",
    "/workspace/_agents/hooks.json",
    "/workspace/_agent/hooks.json",
]


def _check(name, ok, **details):
    return {
        "section": "antigravity",
        "name": name,
        "verdict": "OK" if ok else "DRIFT",
        "details": details,
    }


def _load(path):
    try:
        with open(path) as fh:
            return json.load(fh), None
    except FileNotFoundError:
        return None, "missing"
    except (OSError, ValueError) as exc:
        return None, str(exc)


def _engine(envelope):
    """Run the engine in the antigravity dialect and return its decision."""
    try:
        proc = subprocess.run(
            ["sh", ENGINE, "--dialect=antigravity"],
            input=envelope, capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return None, str(exc)
    try:
        return json.loads(proc.stdout).get("decision"), None
    except ValueError:
        return None, "unparseable: %r" % proc.stdout[:200]


def run():
    out = []

    # ---- layer 1: the static, tamper-resistant deny list --------------------
    settings, err = _load(AGY_SETTINGS)
    out.append(_check("agy_settings_parses", settings is not None,
                      path=AGY_SETTINGS, error=err))
    if settings is not None:
        perms = settings.get("permissions") or {}
        deny = perms.get("deny") or []
        out.append(_check("permissions_deny_present", bool(deny),
                          path=AGY_SETTINGS, rule_count=len(deny)))
        missing = {cat: rule for cat, rule in REQUIRED_DENY_SAMPLE.items()
                   if rule not in deny}
        out.append(_check("permissions_deny_categories", not missing,
                          missing=missing, checked=len(REQUIRED_DENY_SAMPLE),
                          note="one sample per category; completeness is owned "
                               "by scripts/antigravity-parity.test.sh"))
        # request-review is agy's default; always-proceed would silently make
        # every unlisted command auto-run, which is the widening this pin exists
        # to make visible.
        mode = settings.get("toolPermission")
        out.append(_check("tool_permission_not_always_proceed",
                          mode != "always-proceed", toolPermission=mode))
        # Convergence must MERGE. If the user's own keys have vanished, the
        # merge became an overwrite somewhere.
        preserved = [k for k in ("colorScheme", "model", "trustedWorkspaces",
                                 "enableTelemetry") if k in settings]
        out.append({
            "section": "antigravity",
            "name": "agy_own_settings_preserved",
            "verdict": "OK",
            "details": {
                "present": preserved,
                "note": ("informational: convergence writes only permissions and "
                         "toolPermission. An empty list is normal on a profile "
                         "where agy has never run."),
            },
        })

    # ---- layer 2: hook registration ----------------------------------------
    hooks, err = _load(HOOKS_JSON)
    out.append(_check("hooks_json_parses", hooks is not None,
                      path=HOOKS_JSON, error=err))
    if hooks is not None:
        spec = hooks.get(HOOK_NAME) or {}
        out.append(_check("guardrail_hook_enabled",
                          spec.get("enabled") is True,
                          hook=HOOK_NAME, enabled=spec.get("enabled")))
        groups = spec.get("PreToolUse") or []
        matchers = [g.get("matcher") for g in groups]
        # "*" and not an enumerated tool list: agy self-updates, and an
        # enumerated regex stops matching a renamed tool in silence.
        out.append(_check("matcher_is_wildcard", matchers == ["*"],
                          matchers=matchers))
        cmds = [h.get("command", "") for g in groups for h in (g.get("hooks") or [])]
        out.append(_check("hook_command_points_at_engine",
                          any(c.split(" ")[0] == ENGINE for c in cmds),
                          commands=cmds, expected=ENGINE))
        out.append(_check("hook_passes_dialect_flag",
                          any("--dialect=antigravity" in c for c in cmds),
                          commands=cmds,
                          note="without it the engine emits claude's '{}', which "
                               "agy reads as DENY on every tool call"))

    # ---- the engine actually behaves ---------------------------------------
    engine_exists = os.path.isfile(ENGINE)
    out.append(_check("engine_present", engine_exists, path=ENGINE))
    if engine_exists:
        behaviours = [
            ("engine_allows_ordinary_command", "allow",
             '{"toolCall":{"name":"run_command","args":{"CommandLine":"ls -la"}}}'),
            ("engine_denies_destructive", "deny",
             '{"toolCall":{"name":"run_command","args":{"CommandLine":"find /tmp -delete"}}}'),
            ("engine_denies_secret_read", "deny",
             '{"toolCall":{"name":"view_file","args":{"AbsolutePath":'
             '"/root/.gemini/antigravity-cli/antigravity-oauth-token"}}}'),
            ("engine_denies_workspace_hook_write", "deny",
             '{"toolCall":{"name":"write_to_file","args":{"TargetFile":'
             '"/workspace/p/.agents/hooks.json","CodeContent":"{}"}}}'),
            # Fail-closed. An `allow` here would mean a broken envelope sails
            # through, which for reads is the only control agy has.
            ("engine_fails_closed_on_garbage", "deny", "not json at all"),
        ]
        for name, want, envelope in behaviours:
            got, gerr = _engine(envelope)
            out.append(_check(name, got == want,
                              expected=want, got=got, error=gerr))

    # ---- the measured bypass ------------------------------------------------
    shadows = sorted({p for pat in WORKSPACE_HOOK_GLOBS for p in glob.glob(pat)})
    details = {
        "found": shadows,
        "note": ("a workspace hooks.json outranks the global one and can disable "
                 "it by name; the engine blocks the write, so anything found here "
                 "arrived by another route and must be reviewed by hand"),
    }
    out.append(_check("workspace_hook_shadow", not shadows, **details))

    # ---- convergence did not eat live agy state -----------------------------
    present = [n for n in AGY_CONFIG_SIBLINGS
               if os.path.exists(os.path.join("/root/.gemini/config", n))]
    out.append({
        "section": "antigravity",
        "name": "agy_config_siblings_intact",
        "verdict": "OK",
        "details": {
            "present": present,
            "note": ("informational: these are live agy state sharing the "
                     "directory with our hooks.json. Convergence is file-scoped "
                     "so they survive; a profile where agy never ran has none."),
        },
    })

    return out


if __name__ == "__main__":
    import sys
    json.dump(run(), sys.stdout, indent=2)
    print()
