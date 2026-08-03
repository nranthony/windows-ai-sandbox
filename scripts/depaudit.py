#!/usr/bin/env python3
"""depaudit — dependency posture scanner (read-only, offline, stdlib-only).

Answers one question per repo: *which dependency-supply-chain controls are
configured?* It does NOT resolve, install, or reach the network.

Design constraints (docs/_archive/dependency-guardrails-plan.md D1, D2 and plan 01 §1):

  * **Zero third-party dependencies.** A supply-chain audit tool must not have a
    supply chain of its own; it has to be auditable by reading it. Python 3.11+
    stdlib only — no PyYAML, no requests. Mirrors sandbox_templates/bin/webfetch.
  * **Read-only.** Never writes to the target, never installs, never runs a
    package manager. Lockfiles are PARSED, not executed: building an environment
    to enumerate one is the dangerous act this is meant to avoid.
  * **`posture` is offline. `pkg` and `deps` are not.** The posture command makes
    no network call at all and must stay that way — it runs from tier-1 `verify`,
    which has to work with egress down. The `pkg`/`deps` commands query OSV and
    say so; `--offline` degrades them to UNKNOWN rather than silently passing.
    They are host-side by design: `api.osv.dev` is deliberately NOT in
    `proxy/allowed_domains.txt`, so this costs no egress surface inside any
    profile. If it ever moves in-container, that stops being true.
  * **Evidence with every verdict.** A finding carries the file and line that
    produced it, so it is actionable without re-investigation.

Statuses: PASS · FAIL · WARN · N/A (toolchain absent) · UNKNOWN (could not tell).
`N/A` and `UNKNOWN` are distinct on purpose — plan 01 §1 is explicit that an
unknown must never be reported as a pass.

Usage:
    depaudit.py posture <path> [--format md|json] [--fail-on fail|warn|never]
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

PASS, FAIL, WARN, NA, UNKNOWN = "PASS", "FAIL", "WARN", "N/A", "UNKNOWN"

# Instruction files are executable surfaces: an install command written into one
# gets run by the next agent and pasted by the next human (X04).
DOC_TARGETS = (
    "AGENTS.md", "CLAUDE.md", "GEMINI.md", "SKILL.md", "README.md",
    "CONTRIBUTING.md", ".cursorrules",
)

INSTALL_CMD = re.compile(
    r"(?:^|[^\w-])("
    r"npm\s+(?:i|install|add)|pnpm\s+(?:add|install|dlx)|yarn\s+add|bun\s+add"
    r"|pip3?\s+install|uv\s+add|uv\s+pip\s+install|pipx\s+install|poetry\s+add"
    r"|cargo\s+(?:install|add)|go\s+(?:install|get)"
    r")\s+([^\s`'\"]+)"
)

MANIFESTS = ("package.json", "pyproject.toml", "requirements.txt", "Pipfile")


@dataclass
class Finding:
    id: str
    status: str
    title: str
    detail: str = ""
    file: str = ""
    line: int = 0
    fix: str = ""

    def loc(self) -> str:
        if not self.file:
            return ""
        return f"{self.file}:{self.line}" if self.line else self.file


@dataclass
class Report:
    root: str
    ecosystems: list[str] = field(default_factory=list)
    package_managers: list[str] = field(default_factory=list)
    findings: list[Finding] = field(default_factory=list)

    def add(self, *a, **kw) -> None:
        self.findings.append(Finding(*a, **kw))

    def counts(self) -> dict[str, int]:
        c: dict[str, int] = {}
        for f in self.findings:
            c[f.status] = c.get(f.status, 0) + 1
        return c


# --------------------------------------------------------------------------
# helpers — deliberately small and total; a parse failure must degrade to
# UNKNOWN rather than raise, because a crashed scanner reports nothing.
# --------------------------------------------------------------------------

def read(p: Path) -> str:
    try:
        return p.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def find_line(text: str, pattern: str) -> int:
    """1-indexed line of the first regex match, else 0."""
    for n, line in enumerate(text.splitlines(), 1):
        if re.search(pattern, line):
            return n
    return 0


def ini_get(path: Path, key: str) -> tuple[str | None, int]:
    """Value + line for `key=value` in an npmrc/pip.conf-style file.

    Ignores commented lines. Returns the LAST occurrence, matching how these
    files are read (later wins within one file).
    """
    text = read(path)
    val, ln = None, 0
    for n, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if not s or s.startswith(("#", ";")):
            continue
        # npm array config is `key[]=value`; without the optional `[]` this
        # silently misses every list-valued setting (e.g. an exemption list).
        m = re.match(rf"{re.escape(key)}(?:\[\])?\s*=\s*(.*)$", s)
        if m:
            val, ln = m.group(1).strip(), n
    return val, ln


def yaml_lookup(path: Path, dotted: str) -> tuple[str | None, int]:
    """Minimal YAML probe for `a.b` scalar/list keys — no PyYAML (D2).

    Handles only the shapes pnpm-workspace.yaml actually uses: top-level keys,
    one level of nesting, `key: value`, `key: [a, b]`, and `- item` blocks.
    Anything else returns None, which callers must treat as UNKNOWN rather than
    absent.
    """
    text = read(path)
    if not text:
        return None, 0
    parts = dotted.split(".")
    want_top, want_sub = parts[0], (parts[1] if len(parts) > 1 else None)
    lines = text.splitlines()
    top_indent = None
    for n, raw in enumerate(lines, 1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip())
        m = re.match(r"([A-Za-z0-9_-]+)\s*:\s*(.*)$", raw.strip())
        if indent == 0 and m and m.group(1) == want_top:
            if want_sub is None:
                inline = m.group(2).strip()
                if inline:
                    return inline, n
                # collect the block beneath
                block = []
                for r2 in lines[n:]:
                    if r2.strip() and (len(r2) - len(r2.lstrip())) == 0:
                        break
                    block.append(r2.strip())
                return ("\n".join(x for x in block if x) or None), n
            top_indent = indent
            continue
        if top_indent is not None:
            if raw.strip() and indent <= top_indent:
                break  # left the block
            if m and m.group(1) == want_sub:
                return (m.group(2).strip() or ""), n
    return None, 0


def git(root: Path, *args: str) -> str:
    """Read-only git query. Empty string if not a repo or git is unavailable."""
    try:
        r = subprocess.run(
            ["git", "-C", str(root), *args],
            capture_output=True, text=True, timeout=20,
        )
        return r.stdout if r.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def in_git(root: Path) -> bool:
    """Is this path inside a work tree?

    Checking for a `.git` entry at the scan root is wrong: a monorepo member
    (`apps/dashboard`) or any subdirectory is inside a repo without containing
    `.git` itself, so the git-backed checks would report UNKNOWN for the common
    `profile.sh deps` case of scanning nested projects.
    """
    return git(root, "rev-parse", "--is-inside-work-tree").strip() == "true"


def tracked(root: Path, rel: str) -> bool | None:
    """True/False if git can say; None if this is not inside a work tree."""
    if not in_git(root):
        return None
    return bool(git(root, "ls-files", "--", rel).strip())


# --------------------------------------------------------------------------
# discover — fingerprint before checking, so a repo is never marked FAIL for a
# toolchain it does not use (plan 01 §3).
# --------------------------------------------------------------------------

def discover(root: Path, rep: Report) -> dict:
    marks = {
        "npm": (root / "package-lock.json").exists(),
        "pnpm": (root / "pnpm-lock.yaml").exists() or (root / "pnpm-workspace.yaml").exists(),
        "yarn": (root / "yarn.lock").exists(),
        "bun": (root / "bun.lock").exists() or (root / "bun.lockb").exists(),
        "uv": (root / "uv.lock").exists(),
        "poetry": (root / "poetry.lock").exists(),
        "pdm": (root / "pdm.lock").exists(),
        "pipenv": (root / "Pipfile.lock").exists(),
    }
    pkg = root / "package.json"
    declared = ""
    if pkg.exists():
        try:
            declared = (json.loads(read(pkg)) or {}).get("packageManager", "") or ""
        except json.JSONDecodeError:
            declared = ""
        if declared:
            marks[declared.split("@")[0]] = True

    node = [k for k in ("npm", "pnpm", "yarn", "bun") if marks[k]]
    py = [k for k in ("uv", "poetry", "pdm", "pipenv") if marks[k]]
    reqs = sorted(root.glob("requirements*.txt"))
    if reqs and not py:
        py = ["pip"]

    rep.package_managers = node + py
    if node:
        rep.ecosystems.append("node")
    if py or reqs:
        rep.ecosystems.append("python")

    # Competing Node lockfiles mean resolution is nondeterministic depending on
    # who runs what — one of them is stale and unenforced (plan 01 §3).
    node_locks = [n for n in ("package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock")
                  if (root / n).exists()]
    if len(node_locks) > 1:
        rep.add("D01", FAIL, "Multiple Node lockfiles present",
                f"{', '.join(node_locks)} — resolution depends on which tool is run",
                file=node_locks[0],
                fix="Keep one lockfile; delete the others and pin `packageManager`")
    elif node:
        rep.add("D01", PASS, "Single Node lockfile", ", ".join(node_locks) or "none")

    # Nested projects. This scan is root-scoped, so anything one level down is
    # unchecked and would otherwise read as clean.
    #
    # This used to fire only when the root had NO manifests at all, which made it
    # blind to the shape it matters most for: a monorepo WITH a root manifest and
    # real projects underneath. Those children were never reported as unchecked,
    # so "posture: clean" meant only "the root is clean". The gate now keys on
    # whether nested manifests exist, not on whether the root is empty; the
    # wording distinguishes the two cases because the advice differs.
    # Depth 1 AND 2: `packages/<name>/package.json` is the standard pnpm/npm
    # workspace layout, and a depth-1-only glob (`*/package.json`) misses every
    # one of them — it only ever matched `apps/package.json`, which nobody writes.
    nested = sorted({
        str(p.parent.relative_to(root))
        for name in ("package.json", "pyproject.toml")
        for pat in (f"*/{name}", f"*/*/{name}")
        for p in root.glob(pat)
        if not skipped(p, root)
    })
    if nested and not node and not py and not reqs:
        rep.add("D03", WARN, "No manifests at the repo root, but nested projects exist",
                "This scan is root-scoped and did NOT check them — rerun per directory: "
                + ", ".join(nested[:8]) + (" …" if len(nested) > 8 else ""),
                fix="depaudit posture <path>/" + nested[0])
    elif nested:
        rep.add("D03", WARN, "Nested projects were not checked by this root-scoped scan",
                "The root has its own manifest, so the checks above describe the ROOT ONLY. "
                "These children carry their own dependency sets: "
                + ", ".join(nested[:8]) + (" …" if len(nested) > 8 else ""),
                fix="depaudit posture <path>/" + nested[0]
                    + "   (or `profile.sh <p> deps`, which iterates children)")

    if node and not declared:
        rep.add("D02", WARN, "No `packageManager` pin in package.json",
                "Tool selection is inferred from lockfile markers, not declared",
                file="package.json",
                fix='Add "packageManager": "pnpm@<version>"')
    elif declared:
        rep.add("D02", PASS, "packageManager pinned", declared, file="package.json")

    return {"marks": marks, "declared": declared, "reqs": reqs, "node": node, "py": py}


# --------------------------------------------------------------------------
# Node posture
# --------------------------------------------------------------------------

SKIP_DIRS = {"node_modules", ".venv", ".git", "venv", "__pycache__"}


def skipped(p: Path, root: Path) -> bool:
    """Is this path inside vendored / installed third-party code?

    A literal name set is not enough. Virtualenvs are routinely named `.venv-linux`,
    `.venv311`, `env`, and their `site-packages` trees carry thousands of READMEs
    and `.npmrc` files belonging to OTHER projects. One live example: scanning a
    real workspace surfaced `pip install babel` from
    `pipeline/.venv-linux/.../jupyter_server/i18n/README.md` — a third party's
    documentation, reported as if the user's own repo had written it.

    `site-packages` / `dist-packages` are the reliable markers, since any venv
    layout ends up with one regardless of what the top directory is called.
    """
    parts = p.relative_to(root).parts
    if SKIP_DIRS & set(parts):
        return True
    return any(part in ("site-packages", "dist-packages") or part.startswith(".venv")
               or part in ("venv", "env", ".env", ".tox", ".nox", "vendor")
               for part in parts)


def _child_rc_files(root: Path, max_depth: int = 4) -> list[Path]:
    """Config files below the root that can override the quarantine.

    Depth cap mirrors the container-side sweep in verify-sandbox.sh, which uses
    `find -maxdepth 4`; the two are meant to see the same set.
    """
    out: list[Path] = []
    for name in (".npmrc", "pnpm-workspace.yaml"):
        for p in root.rglob(name):
            rel = p.relative_to(root)
            if len(rel.parts) < 2 or len(rel.parts) > max_depth:
                continue  # root-level file is N02/N02p's job
            if skipped(p, root) or any(q.is_symlink() for q in p.parents
                                       if q != root and root in q.parents):
                continue
            out.append(p)
    return sorted(out)


def check_child_quarantine(root: Path, rep: Report) -> None:
    """N03 — a child directory can switch the age gate off for itself.

    npm/pnpm config precedence is `cli > env > project > user > global`, so a
    per-member `.npmrc` or `pnpm-workspace.yaml` inside a monorepo child silently
    overrides the sandbox-wide quarantine for installs run from that directory.
    Nothing else sees this: the deny-list and the hook rules key on COMMANDS and
    on root manifests, and N02/N02p only read the root.

    Thresholds are absolute rather than compared against a live baseline. This
    runs host-side against arbitrary repos, where no baseline exists; the
    live-comparison form of this check is the G10 block in verify-sandbox.sh,
    which reads the real `npm config get --location=global` inside the container.
    Treat the two as the static and dynamic halves of one control.

    ABSENCE IS NOT A FINDING, unlike root N02/N02p. A child with no rc file
    inherits the global window, which is the wanted state — flagging it would
    fire on every healthy monorepo member and teach people to ignore N03.
    """
    weak: list[tuple[str, int, str]] = []
    broken: list[tuple[str, int, str]] = []
    fine = 0

    for p in _child_rc_files(root):
        rel = str(p.relative_to(root))
        if p.name == ".npmrc":
            # npm counts DAYS, pnpm counts MINUTES; normalise to minutes so one
            # threshold serves both. Getting this backwards is a 1440x error.
            for key, mult in (("min-release-age", 1440), ("minimum-release-age", 1)):
                val, ln = ini_get(p, key)
                if val is None:
                    continue
                if not val.isdigit():
                    broken.append((rel, ln, f"{key}={val}"))
                elif int(val) == 0:
                    weak.append((rel, ln, f"{key}=0 (quarantine off)"))
                elif int(val) * mult < 1440:
                    weak.append((rel, ln, f"{key}={val} (under 24h)"))
                else:
                    fine += 1
        else:
            val, ln = yaml_lookup(p, "minimumReleaseAge")
            if val is None:
                continue
            val = val.strip()
            if not val.isdigit():
                broken.append((rel, ln, f"minimumReleaseAge: {val}"))
            elif int(val) == 0:
                weak.append((rel, ln, "minimumReleaseAge: 0 (quarantine off)"))
            elif int(val) < 1440:
                weak.append((rel, ln, f"minimumReleaseAge: {val} (under 24h)"))
            else:
                fine += 1

    if broken:
        rel, ln, what = broken[0]
        rep.add("N03", FAIL, "Child quarantine value is not a plain integer",
                f"{what} in {rel} — a suffixed value gives an Invalid Date cutoff and "
                "REJECTS EVERY VERSION, which fails closed and presents as a broken "
                "registry" + (f"; {len(broken)} such files" if len(broken) > 1 else ""),
                file=rel, line=ln, fix="Use plain minutes, e.g. 10080 for 7 days")
    elif weak:
        rel, ln, what = weak[0]
        rep.add("N03", FAIL, "A child directory weakens the resolution quarantine",
                f"{what} in {rel} — config precedence is cli > env > project > user > "
                "global, so this overrides the global window for installs run from that "
                "directory" + (f"; {len(weak)} such files" if len(weak) > 1 else ""),
                file=rel, line=ln,
                fix="Remove the override so the child inherits the global window, or raise "
                    "it to at least 1440 minutes (10080 = 7d)")
    elif fine:
        rep.add("N03", PASS, "Child quarantine overrides are at least as strong",
                f"{fine} nested override(s) checked, none weaker than 24h")


def check_node(root: Path, rep: Report, ctx: dict) -> None:
    if not ctx["node"]:
        rep.add("N00", NA, "Node toolchain not present", "no Node lockfile or manifest")
        # A child .npmrc can still switch the gate off for a nested project even
        # when the ROOT has no Node toolchain, so this runs before the bail.
        check_child_quarantine(root, rep)
        return

    npmrc = root / ".npmrc"
    ws = root / "pnpm-workspace.yaml"
    uses_pnpm = "pnpm" in ctx["node"]

    # --- N01: install scripts -------------------------------------------
    # This is where a slopsquat payload runs, so it outranks the age gate.
    #
    # THE DEFAULT IS BLOCKED, AND THE ALLOWLIST IS THE HOLE. pnpm 10 does not run
    # dependency lifecycle scripts at all unless a package is named in
    # `allowBuilds` / `onlyBuiltDependencies`. Verified 2026-08-02: a bare install
    # prints "Ignored build scripts: esbuild@0.25.0"; adding either key silences
    # it and lets the script run.
    #
    # An earlier version of this check had it exactly backwards — it FAILed a repo
    # for having no allowlist, i.e. for being in the safest possible state, and
    # would have pushed someone to punch a hole to make the scanner happy. Worth
    # the comment: the intuition "a list of allowed things = a control" is wrong
    # here, and it is the second inverted assumption this scanner has shipped.
    ignore, ln = ini_get(npmrc, "ignore-scripts")
    allow_builds, wl = yaml_lookup(ws, "allowBuilds")
    only_built, ol = yaml_lookup(ws, "onlyBuiltDependencies")

    exempt: list[str] = []
    src_file, src_line = "", 0
    if allow_builds is not None:
        exempt = [x.split(":")[0].strip() for x in allow_builds.splitlines() if ":" in x]
        src_file, src_line = "pnpm-workspace.yaml", wl
    elif only_built is not None:
        exempt = [x.lstrip("- ").strip() for x in only_built.splitlines()
                  if x.strip().startswith("-")] or ["(inline list)"]
        src_file, src_line = "pnpm-workspace.yaml", ol

    if uses_pnpm:
        if not exempt:
            rep.add("N01", PASS, "Install scripts blocked for every dependency",
                    "pnpm 10 runs no dependency lifecycle scripts unless allowlisted, and "
                    "nothing is allowlisted here — the strongest available posture",
                    file="pnpm-workspace.yaml" if ws.exists() else "")
        elif len(exempt) <= 3:
            rep.add("N01", PASS, "Install scripts blocked except for a named allowlist",
                    f"{len(exempt)} exemption(s): {', '.join(exempt)} — each may run "
                    "arbitrary code at install time; keep the list this short",
                    file=src_file, line=src_line)
        else:
            rep.add("N01", WARN, "Install-script allowlist is broad",
                    f"{len(exempt)} packages may run arbitrary code at install time: "
                    + ", ".join(exempt[:8]) + (" …" if len(exempt) > 8 else ""),
                    file=src_file, line=src_line,
                    fix="Trim to packages that genuinely need a native build step")
    elif ignore == "true":
        rep.add("N01", PASS, "Install scripts blocked", "ignore-scripts=true",
                file=".npmrc", line=ln)
    else:
        # npm >= 12 blocks by default via its allow-scripts allowlist, but the
        # installed version cannot be confirmed from the repo alone.
        rep.add("N01", UNKNOWN, "Install-script policy not declared in-repo",
                "npm >=12 blocks by default, but nothing here pins that",
                fix="Set ignore-scripts=true in .npmrc to make it explicit and version-proof")

    # --- N02 / N02p: resolution age gate ----------------------------------
    # BOTH locations are valid for this setting, and that is not obvious.
    # Measured 2026-08-02 with a deliberately absurd 10-year window: the install
    # failed with the value in .npmrc AND with it in pnpm-workspace.yaml, so both
    # are enforced. Do NOT generalise from `supportedArchitectures`, which IS
    # ignored in .npmrc — the difference is scalar vs nested-object settings, and
    # an earlier draft of this check failed the .npmrc form on that false analogy.
    # A false FAIL here is worse than no check: it trains people to ignore output.
    npm_age, nl = ini_get(npmrc, "min-release-age")
    pnpm_age_rc, pl = ini_get(npmrc, "minimum-release-age")
    pnpm_age_ws, wl2 = yaml_lookup(ws, "minimumReleaseAge")

    if uses_pnpm:
        age, src, sl = ((pnpm_age_ws, "pnpm-workspace.yaml", wl2) if pnpm_age_ws is not None
                        else (pnpm_age_rc, ".npmrc", pl))
        if age is None:
            rep.add("N02p", FAIL, "No pnpm resolution quarantine",
                    "A freshly-published (or freshly-hijacked) version can be installed the "
                    "minute it appears",
                    file="pnpm-workspace.yaml" if ws.exists() else ".npmrc",
                    fix="Add `minimumReleaseAge: 10080` (minutes = 7d) to pnpm-workspace.yaml, "
                        "or `minimum-release-age=10080` to .npmrc — both are honoured")
        elif not age.isdigit():
            # A suffixed value is worse than off: pnpm computes value*60*1e3, so
            # it yields NaN -> Invalid Date -> every version rejected. Fails
            # closed and presents as a broken registry.
            rep.add("N02p", FAIL, "pnpm quarantine value is not a plain integer",
                    f"{age!r} — pnpm computes value*60*1000, so a suffixed form gives an "
                    "Invalid Date cutoff and REJECTS EVERY VERSION; nothing will resolve",
                    file=src, line=sl,
                    fix="Use plain minutes, e.g. 10080 for 7 days")
        elif int(age) == 0:
            rep.add("N02p", FAIL, "pnpm quarantine disabled", "minimumReleaseAge=0",
                    file=src, line=sl, fix="Set 1440 (24h) at minimum; 10080 = 7d")
        elif int(age) < 1440:
            rep.add("N02p", WARN, "pnpm quarantine under one day",
                    f"{age} minutes — note the unit is MINUTES, so a day-count entered here "
                    "(e.g. 7) is a 1440x error that fails open",
                    file=src, line=sl)
        else:
            rep.add("N02p", PASS, "pnpm resolution quarantine",
                    f"{age} minutes ({int(age)//1440}d) via {src}", file=src, line=sl)

    if "npm" in ctx["node"]:
        if npm_age and npm_age.isdigit() and int(npm_age) >= 1:
            rep.add("N02", PASS, "npm resolution quarantine",
                    f"min-release-age={npm_age} day(s)", file=".npmrc", line=nl)
        elif npm_age is not None:
            rep.add("N02", FAIL, "npm quarantine disabled or malformed",
                    f"min-release-age={npm_age} (unit is DAYS; a suffixed value does not parse)",
                    file=".npmrc", line=nl)
        else:
            rep.add("N02", FAIL, "No npm resolution quarantine", "min-release-age unset",
                    file=".npmrc" if npmrc.exists() else "",
                    fix="Add `min-release-age=7` to .npmrc (unit is DAYS, unlike pnpm)")

    check_child_quarantine(root, rep)

    # --- N04 / N05: registry pinning --------------------------------------
    reg, rl = ini_get(npmrc, "registry")
    if reg:
        rep.add("N04", PASS, "Registry pinned", reg, file=".npmrc", line=rl)
    else:
        rep.add("N04", WARN, "Registry not pinned in-repo",
                "Resolution follows whatever the ambient npm config says",
                fix="Add `registry=https://registry.npmjs.org/` (or your mirror)")

    scoped = []
    for n, line in enumerate(read(npmrc).splitlines(), 1):
        if re.match(r"\s*@[\w.-]+:registry\s*=", line) and not line.strip().startswith("#"):
            scoped.append((line.strip(), n))
    if scoped:
        rep.add("N05", WARN, "Scoped registries configured",
                "; ".join(s for s, _ in scoped) + " — each is an additional trusted source",
                file=".npmrc", line=scoped[0][1])

    # --- N06: lockfile committed ------------------------------------------
    for lock in ("pnpm-lock.yaml", "package-lock.json", "yarn.lock", "bun.lock"):
        if not (root / lock).exists():
            continue
        t = tracked(root, lock)
        if t is True:
            rep.add("N06", PASS, "Lockfile committed", lock, file=lock)
        elif t is False:
            rep.add("N06", FAIL, "Lockfile present but NOT committed",
                    f"{lock} is untracked — every install resolves fresh and ungated",
                    file=lock, fix=f"git add {lock}")
        else:
            rep.add("N06", UNKNOWN, "Cannot determine lockfile tracking", "not a git repo",
                    file=lock)

    # --- N11: exemptions carry a reason -----------------------------------
    for key in ("min-release-age-exclude", "minimumReleaseAgeExclude"):
        val, ln2 = ini_get(npmrc, key)
        if val:
            lines = read(npmrc).splitlines()
            prev = lines[ln2 - 2].strip() if ln2 >= 2 else ""
            if prev.startswith("#"):
                rep.add("N11", PASS, "Quarantine exemption is justified",
                        f"{key}={val}", file=".npmrc", line=ln2)
            else:
                rep.add("N11", WARN, "Quarantine exemption with no stated reason",
                        f"{key}={val} — an unexplained exemption outlives the reason for it",
                        file=".npmrc", line=ln2,
                        fix="Add a comment line above it saying why")


# --------------------------------------------------------------------------
# Python posture
# --------------------------------------------------------------------------

def check_python(root: Path, rep: Report, ctx: dict) -> None:
    reqs, py = ctx["reqs"], ctx["py"]
    if not py and not reqs and not (root / "pyproject.toml").exists():
        rep.add("P00", NA, "Python toolchain not present", "no Python manifest or lockfile")
        return

    pyproject = root / "pyproject.toml"
    data: dict = {}
    if pyproject.exists():
        try:
            data = tomllib.loads(read(pyproject))
        except (tomllib.TOMLDecodeError, ValueError) as e:
            rep.add("P00", UNKNOWN, "pyproject.toml could not be parsed", str(e),
                    file="pyproject.toml")

    # --- P03: a lockfile exists at all ------------------------------------
    locks = [n for n in ("uv.lock", "poetry.lock", "pdm.lock", "Pipfile.lock")
             if (root / n).exists()]
    if locks:
        rep.add("P03", PASS, "Python lockfile present", ", ".join(locks), file=locks[0])
    elif reqs:
        rep.add("P03", WARN, "requirements.txt without a lockfile",
                "Bare pip is the weakest posture: no native age gate and no resolution record",
                file=reqs[0].name)
    else:
        rep.add("P03", FAIL, "No Python lockfile", "Resolution is not reproducible")

    # --- P02: hash pinning ------------------------------------------------
    for r in reqs:
        text = read(r)
        entries = [l for l in text.splitlines()
                   if l.strip() and not l.strip().startswith(("#", "-"))]
        if not entries:
            continue
        if "--hash=" in text:
            missing = [l for l in entries if "--hash=" not in l and not l.rstrip().endswith("\\")]
            if missing:
                rep.add("P02", WARN, "Partial hash pinning", f"{len(missing)} entry(ies) unhashed",
                        file=r.name)
            else:
                rep.add("P02", PASS, "Requirements are hash-pinned", r.name, file=r.name)
        else:
            rep.add("P02", WARN, "No hash pinning", f"{r.name} has no --hash entries",
                    file=r.name, fix="pip-compile --generate-hashes, then --require-hashes")

    # --- P04: uv resolution quarantine ------------------------------------
    excl = (data.get("tool", {}).get("uv", {}) or {}).get("exclude-newer")
    if "uv" in py:
        if excl:
            rep.add("P04", PASS, "uv resolution pinned by date", f"exclude-newer={excl}",
                    file="pyproject.toml",
                    line=find_line(read(pyproject), r"exclude-newer"))
        else:
            rep.add("P04", WARN, "No uv resolution quarantine",
                    "uv has no relative age window; exclude-newer takes a timestamp and must be "
                    "maintained. Outside a gated network this is the only uv-side control",
                    file="pyproject.toml")
    elif reqs:
        rep.add("P04", NA, "pip has no native age gate",
                "Must be enforced by the network boundary or a proxy")

    # --- P05 / P06: index configuration -----------------------------------
    # P06 is the sharp one: extra-index-url is a dependency-confusion vector,
    # because pip may prefer whichever index offers the higher version.
    found_index = found_extra = False
    for cfg in (root / "pip.conf", root / "pip.ini", root / ".pip" / "pip.conf"):
        if not cfg.exists():
            continue
        iu, il = ini_get(cfg, "index-url")
        eu, el = ini_get(cfg, "extra-index-url")
        if iu:
            found_index = True
            rep.add("P05", PASS, "pip index pinned", iu, file=cfg.name, line=il)
        if eu:
            found_extra = True
            rep.add("P06", FAIL, "extra-index-url is set",
                    f"{eu} — dependency-confusion vector: pip may prefer whichever index "
                    "offers the higher version",
                    file=cfg.name, line=el, fix="Remove it; use a single index or a mirror")
    if (py or reqs) and not found_index:
        rep.add("P05", WARN, "pip index not pinned in-repo", "Follows ambient pip config")
    if (py or reqs) and not found_extra:
        rep.add("P06", PASS, "No extra-index-url", "No dependency-confusion vector configured")

    # --- P08: sdists resolve to arbitrary code at build time --------------
    ulock = root / "uv.lock"
    if ulock.exists():
        try:
            u = tomllib.loads(read(ulock))
            # A package that merely PUBLISHES an sdist is not a finding — almost
            # every package on PyPI does, alongside its wheels, and uv installs
            # the wheel. Only an entry with an sdist and NO wheels actually
            # builds from source. The first version of this check tested
            # `"sdist" in p` and over-reported by ~87x: measured across 16 real
            # lockfiles, 522 of 565 distinct packages "have an sdist" while just
            # 6 are sdist-only. That wrong number is what gated T23 for days —
            # `dashboard` was cited as having "45 sdists" when its true count is
            # zero. No wheels AND no source = a local/editable/virtual entry,
            # which is not a download at all.
            sdists = sorted({p.get("name", "?") for p in u.get("package", [])
                             if "sdist" in p and not p.get("wheels") and p.get("source")})
            if sdists:
                rep.add("P08", WARN, "Dependencies that can ONLY build from source",
                        f"{len(sdists)} package(s) have no wheel, so installing them runs "
                        f"setup.py/PEP-517 build code: {', '.join(sdists[:8])}"
                        + (" …" if len(sdists) > 8 else ""),
                        file="uv.lock",
                        fix="These are what a wheels-only policy blocks. Either vendor a "
                            "wheel, drop the dependency, or declare `no-build = false` in "
                            "this project's uv.toml with a stated reason (ADR-0004)")
            else:
                rep.add("P08", PASS, "Every dependency has a wheel",
                        "nothing builds from source at install time", file="uv.lock")
        except (tomllib.TOMLDecodeError, ValueError):
            rep.add("P08", UNKNOWN, "uv.lock could not be parsed", file="uv.lock")


# --------------------------------------------------------------------------
# Cross-cutting
# --------------------------------------------------------------------------

def check_cross(root: Path, rep: Report, ctx: dict) -> None:
    # --- X01: manifests under review --------------------------------------
    co = next((p for p in (root / "CODEOWNERS", root / ".github" / "CODEOWNERS")
               if p.exists()), None)
    if co:
        text = read(co)
        covered = [m for m in MANIFESTS + (".npmrc", "pnpm-workspace.yaml") if m in text]
        if covered:
            rep.add("X01", PASS, "Manifests under CODEOWNERS", ", ".join(covered),
                    file=str(co.relative_to(root)))
        else:
            rep.add("X01", WARN, "CODEOWNERS exists but does not cover manifests",
                    "A dependency change can merge without a named reviewer",
                    file=str(co.relative_to(root)))
    else:
        rep.add("X01", WARN, "No CODEOWNERS", "No path-based review gate on dependency changes")

    # --- X04: instruction files are executable surfaces -------------------
    # The check most implementations skip, and the one this estate is most
    # exposed to: an install command in AGENTS.md is executed by the next agent.
    # Scans the WHOLE tree, not just the root and docs/. The previous globs were
    # `<name>` plus `docs/**/<name>`, which missed the shape that matters most in
    # a monorepo: apps/<x>/README.md and packages/<x>/AGENTS.md are read by an
    # agent working in that subdirectory, and are exactly where a per-app setup
    # instruction lives.
    #
    # Fenced code blocks are NOT excluded, deliberately. An install command inside
    # a ``` block is if anything more likely to be copied verbatim — being tracked
    # here is the point. (An earlier version computed an `in_fence` flag and never
    # used it, so this was already the behaviour; the dead variable is gone.)
    hits: list[tuple[str, int, str, str]] = []
    seen_docs: set[Path] = set()
    for name in DOC_TARGETS:
        for p in sorted(root.rglob(name)):
            if skipped(p, root) or p in seen_docs:
                continue
            seen_docs.add(p)
            for n, line in enumerate(read(p).splitlines(), 1):
                m = INSTALL_CMD.search(line)
                if not m:
                    continue
                arg = m.group(2)
                # A flag is not a package name. `pnpm install --frozen-lockfile`
                # and `npm install -g` name nothing to verify — the first is a
                # LOCKFILE install, whose versions were already held to the age
                # gate when the lockfile was written (the same reason
                # with-egress.sh's extract_specs skips them). Counting them
                # inflates X04 and puts flags in front of the reader as though
                # they were packages.
                if arg.startswith("-"):
                    continue
                # Nor is a shell operator. `npm install && npm run build` captured
                # `&&` and then reported it as a phantom package, which is the
                # false-phantom failure mode in its purest form. A package name
                # starts alphanumeric or `@` (npm scopes) — prose words that happen
                # to follow an install verb still slip through, which is why X04 is
                # a WARN and not a FAIL.
                if not re.match(r"^[@A-Za-z0-9][A-Za-z0-9._@/+-]*$", arg):
                    continue
                hits.append((str(p.relative_to(root)), n, m.group(1).strip(), arg))
    if hits:
        rep.add("X04", WARN, "Install commands in instruction files",
                f"{len(hits)} occurrence(s) — these are run by the next agent and pasted by "
                "the next human; each named package needs the same verification as a manifest "
                "entry: " + "; ".join(f"{f}:{n} `{c} {pkg}`" for f, n, c, pkg in hits[:6])
                + (" …" if len(hits) > 6 else ""),
                file=hits[0][0], line=hits[0][1])
    else:
        rep.add("X04", PASS, "No install commands in instruction files",
                f"checked {', '.join(DOC_TARGETS)}")

    # --- X05: docs name packages the manifests do not have ----------------
    # Reads CHILD manifests as well as the root's, because X04 now finds hits in
    # child docs. An `npm install express` in apps/web/README.md is declared if
    # apps/web/package.json declares it — comparing against the root manifest
    # alone would report it as a phantom, and a false phantom is worse than a
    # missed one: it sends someone hunting for an injection that is not there.
    declared: set[str] = set()
    for pkg in [root / "package.json",
                *sorted(root.glob("*/package.json")),
                *sorted(root.glob("*/*/package.json"))]:
        if not pkg.exists() or skipped(pkg, root):
            continue
        try:
            j = json.loads(read(pkg)) or {}
            for k in ("dependencies", "devDependencies", "optionalDependencies"):
                declared |= set((j.get(k) or {}).keys())
        except json.JSONDecodeError:
            pass
    for pyproject in [root / "pyproject.toml",
                      *sorted(root.glob("*/pyproject.toml")),
                      *sorted(root.glob("*/*/pyproject.toml"))]:
        if not pyproject.exists() or skipped(pyproject, root):
            continue
        try:
            d = tomllib.loads(read(pyproject))
            for dep in (d.get("project", {}) or {}).get("dependencies", []) or []:
                declared.add(re.split(r"[<>=!~\[ ]", dep)[0])
        except (tomllib.TOMLDecodeError, ValueError):
            pass
    # Normalise the doc-named package the SAME way the declared set is built
    # (`re.split(r"[<>=!~\[ ]", dep)[0]` above), or an extras/version form reports
    # as a phantom while the plain name is declared. Live example: docs say
    # `pip install paperbridge[zotero,bibtex]`, pyproject declares
    # `paperbridge[zotero,bibtex] @ git+...` which normalises to `paperbridge` —
    # comparing the raw strings made a correctly-declared package a phantom.
    # A false phantom is worse than a missed one: it sends someone hunting for an
    # injection that does not exist.
    def _norm(name: str) -> str:
        return re.split(r"[<>=!~\[@ ]", name)[0].strip()

    phantom = sorted({_norm(pkg_) for _, _, _, pkg_ in hits
                      if _norm(pkg_) and _norm(pkg_) not in declared
                      and not pkg_.startswith(("-", "."))})
    if phantom:
        rep.add("X05", WARN, "Packages named in docs but absent from manifests",
                "Phantom instruction — a future agent installs a name nothing has vetted: "
                + ", ".join(phantom[:8]) + (" …" if len(phantom) > 8 else ""),
                file=hits[0][0] if hits else "")
    elif hits:
        rep.add("X05", PASS, "Every package named in docs is a declared dependency")

    # --- X07: how dependencies actually got added -------------------------
    # Dependency additions bundled into large feature commits are the pattern
    # that hides an agent-added package.
    if not in_git(root):
        rep.add("X07", UNKNOWN, "Dependency-add provenance unavailable",
                "not inside a git work tree")
        return
    manifest_paths = [m for m in MANIFESTS if (root / m).exists()]
    if not manifest_paths:
        rep.add("X07", NA, "No manifests to trace")
        return
    log = git(root, "log", "--format=%h|%an|%s", "-n", "40", "--", *manifest_paths)
    entries = [l for l in log.splitlines() if l.strip()]
    if not entries:
        rep.add("X07", UNKNOWN, "No manifest history found", file=manifest_paths[0])
        return
    lock_names = [n for n in ("pnpm-lock.yaml", "package-lock.json", "uv.lock", "poetry.lock")
                  if (root / n).exists()]
    risky = []
    for e in entries[:20]:
        sha = e.split("|", 1)[0]
        files = git(root, "show", "--name-only", "--format=", sha).split()
        touched_manifest = any(f.endswith(tuple(manifest_paths)) for f in files)
        touched_lock = any(f.endswith(tuple(lock_names)) for f in files) if lock_names else True
        if touched_manifest and not touched_lock and len(files) > 3:
            risky.append(f"{sha} ({len(files)} files, no lockfile change)")
    if risky:
        rep.add("X07", WARN, "Manifest changed without a matching lockfile change",
                "A manifest edit with no lockfile diff means the next install resolves fresh "
                "and ungated: " + ", ".join(risky[:5]),
                file=manifest_paths[0])
    else:
        rep.add("X07", PASS, "Manifest changes travel with lockfile changes",
                f"last {min(20, len(entries))} manifest commits")


# --------------------------------------------------------------------------
# reporting
# --------------------------------------------------------------------------

ORDER = {FAIL: 0, WARN: 1, UNKNOWN: 2, NA: 3, PASS: 4}
MARK = {PASS: "PASS", FAIL: "FAIL", WARN: "WARN", NA: " N/A", UNKNOWN: "UNKN"}


def render_md(rep: Report) -> str:
    c = rep.counts()
    out = [f"# depaudit posture — {rep.root}", ""]
    out.append("| " + " | ".join(f"{k} {c.get(k,0)}" for k in (FAIL, WARN, UNKNOWN, NA, PASS)) + " |")
    out.append("|" + "---|" * 5)
    out.append("")
    out.append(f"**Ecosystems:** {', '.join(rep.ecosystems) or 'none detected'}  ")
    out.append(f"**Package managers:** {', '.join(rep.package_managers) or 'none detected'}")
    out.append("")
    ranked = sorted(rep.findings, key=lambda f: (ORDER[f.status], f.id))
    actionable = [f for f in ranked if f.status in (FAIL, WARN)]
    if actionable:
        out += ["## Needs attention", ""]
        for f in actionable:
            loc = f" — `{f.loc()}`" if f.loc() else ""
            out.append(f"- **[{f.status}] {f.id} {f.title}**{loc}  ")
            if f.detail:
                out.append(f"  {f.detail}  ")
            if f.fix:
                out.append(f"  *Fix:* {f.fix}")
        out.append("")
    quiet = [f for f in ranked if f.status not in (FAIL, WARN)]
    if quiet:
        # A report that reads as all failures is one people stop opening, so
        # everything that passed collapses to one line each (plan 01 §8).
        out += ["## Passing / not applicable", ""]
        for f in quiet:
            out.append(f"- `[{MARK[f.status]}]` {f.id} {f.title}"
                       + (f" — {f.detail}" if f.detail else ""))
        out.append("")
    return "\n".join(out)


def render_json(rep: Report) -> str:
    return json.dumps({
        "schema": "depaudit/posture/1",
        "root": rep.root,
        "ecosystems": rep.ecosystems,
        "package_managers": rep.package_managers,
        "counts": rep.counts(),
        "findings": [
            {"id": f.id, "status": f.status, "title": f.title, "detail": f.detail,
             "file": f.file, "line": f.line, "fix": f.fix}
            for f in sorted(rep.findings, key=lambda f: (ORDER[f.status], f.id))
        ],
    }, indent=2)


# --------------------------------------------------------------------------
# OSV malicious-package cross-check (T16)
#
# Why only `MAL-`: plan 01 §6 lists OSV as an enrichment source, while §7 lists
# CVE output as an explicit NON-signal that generates noise and false confidence.
# Both are right, and the ID prefix is what reconciles them. `MAL-` records are
# "this package is malicious"; `GHSA-`/`PYSEC-`/`CVE-` are "this version has a
# vulnerability" — a different question, belonging in a different report. Mixing
# them is how a supply-chain gate becomes a CVE treadmill nobody reads.
#
# Reactive by construction: a miss means "nothing known yet", never "safe". The
# resolution quarantine (min-release-age) is what covers the window where every
# intel feed structurally fails — the hours between publication and detection.
# This is the complement, not the primary control.
# --------------------------------------------------------------------------

OSV_BATCH = "https://api.osv.dev/v1/querybatch"
OSV_VULN = "https://api.osv.dev/v1/vulns/"
OSV_ECOSYSTEM = {"npm": "npm", "node": "npm", "pypi": "PyPI", "python": "PyPI",
                 "pip": "PyPI", "cargo": "crates.io", "crates.io": "crates.io", "go": "Go"}

BLOCK, INFO, CLEAN = "BLOCK", "INFO", "NO-KNOWN-MAL"


def purl(eco: str, name: str, version: str | None) -> str:
    e = OSV_ECOSYSTEM.get(eco.lower(), eco)
    return f"pkg:{e}/{name}" + (f"@{version}" if version else "")


class Cache:
    """Content-addressed metadata cache, keyed (purl, UTC date), 24h by design.

    Caches the METADATA, never an artifact. A repeat scan of the same workspace
    must not re-query a shared public API (plan 01 §6).
    """

    def __init__(self, path: Path | None):
        self.path = path
        self.data: dict = {}
        if path and path.exists():
            try:
                self.data = json.loads(path.read_text())
            except (OSError, json.JSONDecodeError):
                self.data = {}

    @staticmethod
    def _today() -> str:
        import datetime
        return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d")

    def get(self, key: str):
        return self.data.get(f"{key}|{self._today()}")

    def put(self, key: str, value) -> None:
        self.data[f"{key}|{self._today()}"] = value

    def flush(self) -> None:
        if not self.path:
            return
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            today = self._today()
            fresh = {k: v for k, v in self.data.items() if k.endswith(f"|{today}")}
            self.path.write_text(json.dumps(fresh))
        except OSError:
            pass


def osv_query(pkgs: list[tuple[str, str, str | None]], timeout: int = 20) -> dict:
    """Batch-query OSV. Returns {purl: [ids]}; raises OSError on network failure.

    Two-step by necessity: querybatch returns only {id, modified} per vuln, so a
    `MAL-` hit must be hydrated via /v1/vulns/{id} to see `withdrawn`. Hits are
    rare, so the second hop costs nothing in practice.
    """
    import urllib.request

    out: dict[str, list[str]] = {}
    for i in range(0, len(pkgs), 100):
        chunk = pkgs[i:i + 100]
        queries = []
        for eco, name, ver in chunk:
            q: dict = {"package": {"name": name,
                                   "ecosystem": OSV_ECOSYSTEM.get(eco.lower(), eco)}}
            if ver:
                q["version"] = ver
            queries.append(q)
        req = urllib.request.Request(
            OSV_BATCH, data=json.dumps({"queries": queries}).encode(),
            headers={"Content-Type": "application/json",
                     "User-Agent": "depaudit (windows-ai-sandbox)"})
        with urllib.request.urlopen(req, timeout=timeout) as f:
            res = json.load(f)
        for (eco, name, ver), r in zip(chunk, res.get("results", [])):
            out[purl(eco, name, ver)] = [v["id"] for v in (r.get("vulns") or [])]
    return out


def osv_hydrate(vuln_id: str, timeout: int = 20) -> dict:
    import urllib.request
    req = urllib.request.Request(
        OSV_VULN + vuln_id,
        headers={"User-Agent": "depaudit (windows-ai-sandbox)"})
    with urllib.request.urlopen(req, timeout=timeout) as f:
        return json.load(f)


def assess(ids: list[str], cache: Cache) -> tuple[str, str]:
    """Verdict + human detail from a list of OSV ids.

    Deliberately narrower than "a MAL- id means block". A wrongly-published
    malicious-package record wired to a hard failure breaks the build for a
    legitimate dependency — the reported May 2026 withdrawal of 157 records
    (FastAPI, Strawberry GraphQL, rdflib) is the worked example. So a withdrawn
    record is INFO: evidence the corpus self-corrected, not a reason to act.
    """
    mal = [i for i in ids if i.startswith("MAL-")]
    if not mal:
        others = len(ids)
        return CLEAN, (f"no malicious-package record"
                       + (f" ({others} non-MAL advisory/ies — a different question, "
                          "see a CVE report)" if others else ""))
    live, withdrawn = [], []
    for mid in mal:
        rec = cache.get(f"vuln:{mid}")
        if rec is None:
            try:
                v = osv_hydrate(mid)
                rec = {"withdrawn": v.get("withdrawn"), "summary": v.get("summary", "")}
                cache.put(f"vuln:{mid}", rec)
            except (OSError, ValueError, json.JSONDecodeError):
                rec = {"withdrawn": None, "summary": ""}
        # NOTE: `withdrawn` is ABSENT on a live record, not null — .get() gives
        # None either way, so absence and null are treated identically here.
        (withdrawn if rec.get("withdrawn") else live).append(
            f"{mid}" + (f" — {rec['summary']}" if rec.get("summary") else ""))
    if live:
        return BLOCK, "; ".join(live)
    return INFO, "withdrawn record(s), not acted on: " + "; ".join(withdrawn)


# --------------------------------------------------------------------------
# lockfile enumeration — parsed, never executed
# --------------------------------------------------------------------------

def enumerate_locked(root: Path) -> list[tuple[str, str, str | None]]:
    """(ecosystem, name, version) for every package a lockfile pins.

    The lockfile is platform-complete: it records EVERY optional platform
    variant regardless of supportedArchitectures. That is what makes one scan,
    run on any machine, cover all of them — there is no per-device scanning to do.
    """
    found: list[tuple[str, str, str | None]] = []

    pnpm = root / "pnpm-lock.yaml"
    if pnpm.exists():
        in_pkgs = False
        for line in read(pnpm).splitlines():
            if re.match(r"^(packages|snapshots):\s*$", line):
                in_pkgs = True
                continue
            if in_pkgs and line and not line.startswith((" ", "\t")):
                in_pkgs = False
            if in_pkgs:
                m = re.match(r"^  '?([^']+?)'?:\s*$", line)
                if m and "@" in m.group(1):
                    spec = m.group(1)
                    # Strip the peer-dependency suffix FIRST. pnpm v9 keys look
                    # like `@scope/pkg@1.2.3(peer@4.5.6)`, and that suffix
                    # contains its own '@' — splitting on the last '@' before
                    # removing it yields the garbage name
                    # `@scope/pkg@1.2.3(peer`, which OSV cannot match, so the
                    # package silently reports as clean. 121 of 869 entries in a
                    # real lockfile hit this.
                    spec = spec.split("(", 1)[0]
                    at = spec.rfind("@")
                    if at > 0:
                        found.append(("npm", spec[:at], spec[at + 1:]))

    plock = root / "package-lock.json"
    if plock.exists():
        try:
            for path_, meta in (json.loads(read(plock)).get("packages") or {}).items():
                if not path_ or "node_modules/" not in path_:
                    continue
                found.append(("npm", path_.split("node_modules/")[-1], meta.get("version")))
        except json.JSONDecodeError:
            pass

    for lock, eco in ((root / "uv.lock", "PyPI"), (root / "poetry.lock", "PyPI")):
        if lock.exists():
            try:
                for p in tomllib.loads(read(lock)).get("package", []):
                    if p.get("name"):
                        found.append((eco, p["name"], p.get("version")))
            except (tomllib.TOMLDecodeError, ValueError):
                pass

    for r in sorted(root.glob("requirements*.txt")):
        for line in read(r).splitlines():
            s = line.strip()
            if not s or s.startswith(("#", "-")):
                continue
            m = re.match(r"([A-Za-z0-9._-]+)\s*==\s*([^\s;]+)", s)
            if m:
                found.append(("PyPI", m.group(1), m.group(2)))

    seen, uniq = set(), []
    for e, n, v in found:
        if (e, n, v) not in seen:
            seen.add((e, n, v))
            uniq.append((e, n, v))
    return uniq


def posture(root: Path) -> Report:
    rep = Report(root=str(root))
    ctx = discover(root, rep)
    check_node(root, rep, ctx)
    check_python(root, rep, ctx)
    check_cross(root, rep, ctx)
    return rep


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="depaudit",
        description="Dependency posture scanner — read-only, offline, stdlib-only.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("posture", help="local configuration checks (NO network)")
    p.add_argument("path", nargs="?", default=".")
    p.add_argument("--format", choices=("md", "json"), default="md")
    p.add_argument("--fail-on", choices=("fail", "warn", "never"), default="fail",
                   help="exit non-zero at this severity (default: fail)")

    default_cache = Path.home() / ".cache" / "depaudit" / "osv.json"
    for name, helptext in (("pkg", "check one package against OSV (network)"),
                           ("deps", "check every lockfile-pinned package (network)")):
        q = sub.add_parser(name, help=helptext)
        if name == "pkg":
            q.add_argument("ecosystem", help="npm | pypi | cargo | go")
            q.add_argument("name")
            q.add_argument("version", nargs="?", default=None)
        else:
            q.add_argument("path", nargs="?", default=".")
        q.add_argument("--format", choices=("md", "json"), default="md")
        q.add_argument("--offline", action="store_true",
                       help="make no network call; report UNKNOWN instead of guessing")
        q.add_argument("--cache", default=str(default_cache))

    args = ap.parse_args(argv)

    if args.cmd == "posture":
        root = Path(args.path).resolve()
        if not root.is_dir():
            print(f"depaudit: not a directory: {root}", file=sys.stderr)
            return 2
        rep = posture(root)
        print(render_json(rep) if args.format == "json" else render_md(rep))
        c = rep.counts()
        if args.fail_on == "never":
            return 0
        if c.get(FAIL):
            return 1
        if args.fail_on == "warn" and c.get(WARN):
            return 1
        return 0

    # ---- pkg / deps: the SAME code path phase 3's install-window pre-flight
    # calls. One implementation of "is this package trustworthy", two invocation
    # contexts — otherwise the scanner and the gate drift and start disagreeing,
    # which is worse than having only one of them (plan 01 §9).
    cache = Cache(Path(args.cache) if args.cache else None)
    if args.cmd == "pkg":
        targets = [(args.ecosystem, args.name, args.version)]
        label = purl(args.ecosystem, args.name, args.version)
    else:
        root = Path(args.path).resolve()
        if not root.is_dir():
            print(f"depaudit: not a directory: {root}", file=sys.stderr)
            return 2
        targets = enumerate_locked(root)
        label = str(root)
        if not targets:
            print(f"depaudit: no lockfile-pinned packages found under {root}",
                  file=sys.stderr)
            return 0

    results: list[tuple[str, str, str]] = []
    if args.offline:
        # An unreachable OSV must never read as PASS (plan 01 §1).
        results = [(purl(e, n, v), UNKNOWN, "offline: not checked") for e, n, v in targets]
    else:
        uncached = [t for t in targets if cache.get(purl(*t)) is None]
        try:
            fresh = osv_query(uncached) if uncached else {}
            for k, ids in fresh.items():
                cache.put(k, ids)
        except (OSError, ValueError, json.JSONDecodeError) as e:
            for t in targets:
                results.append((purl(*t), UNKNOWN, f"OSV unreachable: {e}"))
        if not results:
            for t in targets:
                ids = cache.get(purl(*t)) or []
                verdict, detail = assess(ids, cache)
                results.append((purl(*t), verdict, detail))
    cache.flush()

    blocked = [r for r in results if r[1] == BLOCK]
    unknown = [r for r in results if r[1] == UNKNOWN]
    info = [r for r in results if r[1] == INFO]

    if args.format == "json":
        print(json.dumps({"schema": "depaudit/pkg/1", "target": label,
                          "checked": len(results),
                          "results": [{"purl": p_, "verdict": v, "detail": d}
                                      for p_, v, d in results]}, indent=2))
    else:
        print(f"# depaudit — OSV malicious-package check\n\n**Target:** {label}  ")
        print(f"**Checked:** {len(results)} package(s)  ")
        print(f"**BLOCK {len(blocked)} · INFO {len(info)} · UNKNOWN {len(unknown)} · "
              f"{CLEAN} {len(results)-len(blocked)-len(info)-len(unknown)}**\n")
        for p_, v, d in results:
            if v != CLEAN or len(results) == 1:
                print(f"- **[{v}]** `{p_}`  \n  {d}")
        if not blocked and not unknown and not info and len(results) > 1:
            print(f"No malicious-package records. Note this is REACTIVE: "
                  f"{CLEAN} means nothing is known yet, not that these are safe. "
                  f"The resolution quarantine is what covers the undetected window.")

    return 1 if blocked else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
