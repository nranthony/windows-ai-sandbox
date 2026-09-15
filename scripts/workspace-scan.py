#!/usr/bin/env python3
"""workspace-scan — every repo in every profile workspace, against the
conventions work/0008 rolls out (read-only, offline, stdlib-only).

Host-side by necessity: a container sees only its own profile's workspace, so
the one place every profile is visible at once is the host. It answers, per git
repo:

  agents    AGENTS.md is the source and CLAUDE.md the thin `@AGENTS.md` stub?
            (Claude Code reads CLAUDE.md, agy reads AGENTS.md; anything else
            leaves one agent reading nothing, or two files drifting apart.)
  notice    no sandbox-notice block inside the repo — AGENTS.md, CLAUDE.md or
            GEMINI.md, root or tracked nested? (The sandbox briefs agents from
            their global homes, ADR-0015; a block in a repo goes stale and repo
            agents may not edit inside the markers.)
  settings  .claude/settings.json + settings.local.json: venv paths in allow
            rules, host paths, bare WebFetch, bypass mode, hooks, and whether
            the ask/deny fence around each script catches every spelling.
  python    every venv, whose it is (host or sandbox) and which slot it sits
            in; .venv-sandbox/ ignored; a baked .python-version; hard-coded
            venv names and OS-based venv selection in tracked files.
  local     `.local` files ignored in both shapes; none already tracked.

Design constraints, inherited from scripts/depaudit.py for the same reasons:

  * **Stdlib only.** Python 3.11+ (tomllib is not needed, but the floor keeps
    it aligned with depaudit). No third-party logger either: this prints a
    report, it does not log.
  * **Read-only.** Never writes into a scanned repo, never runs a package
    manager or an interpreter from a scanned venv. Venv ownership is read from
    `pyvenv.cfg` and console-script shebangs, never by executing anything.
  * **Evidence with every finding** — file and line where there is one.
  * **UNKNOWN is not a pass.** A venv whose owner cannot be told apart is
    reported as unknown, never guessed into a clean slot.

THE REPORT NAMES EVERY REPO IN EVERY PROFILE, and this repo is public. So
`--out` refuses a path inside a git work tree unless git ignores it — the
`*.local` / `*.local.*` rule in .gitignore exists for exactly this file.
Stdout is fine; redirecting stdout into the tree is on you.

Roots: every profile under --profiles-dir (tagged by profile — its workspace is
<workspaces-root>/<profile>, bind-mounted into that profile's container), plus
host-only roots from --also or `.workspace-scan.local` (one path per line, `#`
comments). Host-only repos are never mounted into a sandbox, so venv-slot
findings there are informational.

Levels: ACTION (needs a change) · INFO · UNKNOWN (could not tell).

The work/0008 done-check (plan stage 6) is
    workspace-scan.py --fail-on HARDCODED-VENV-LINUX,OS-VENV-SELECT
Those are the only findings that go SILENTLY stale once a profile exports
UV_PROJECT_ENVIRONMENT: a pinned `.venv-linux` keeps running an old, working
venv. A stale `.venv/bin/…` inside the sandbox points at the host's venv and
fails loudly, so it is ordinary cleanup, not part of the check.

The work/0011 done-check is
    workspace-scan.py --fail-on NOTICE-IN-REPO
A notice block cannot come back through a pull unnoticed.

Usage:
    workspace-scan.py [--profiles-dir DIR] [--workspaces-root DIR] [--also DIR]...
                      [--max-depth N] [--format md|json] [--out FILE]
                      [--fail-on ID[,ID...]]
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import platform
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent
ROOTS_FILE = REPO_ROOT / ".workspace-scan.local"

# Mirrors scripts/profile.sh: per-profile state under ~/.ai-sandbox/profiles/<p>,
# workspace at ~/repo/<p> (bind-mounted as /workspace). Ported from macolima,
# where the same two roots sit on an external drive; the checks are identical.
HOME_DIR = Path(os.environ.get("HOME", "~")).expanduser()
DEFAULT_PROFILES_DIR = HOME_DIR / ".ai-sandbox" / "profiles"
DEFAULT_WORKSPACES_ROOT = HOME_DIR / "repo"

ACTION, INFO, UNKNOWN = "ACTION", "INFO", "UNKNOWN"

# The sandbox's venv name (work/0008, docker-compose.yml UV_PROJECT_ENVIRONMENT)
# and the host's (uv's default). Any other `.venv-*` is a legacy slot.
SANDBOX_SLOT, HOST_SLOT = ".venv-sandbox", ".venv"

# Python minors the macolima and windows-ai-sandbox images both bake. A pin to
# anything else cannot resolve offline inside a container.
BAKED_PYTHONS = ("3.12", "3.13")

# Directories never descended into while discovering repos or venvs.
SKIP_DIRS = {
    "node_modules", "__pycache__", "site-packages", ".git", ".tox", ".nox",
    ".mypy_cache", ".pytest_cache", ".ruff_cache", ".cache",
}

# Nested AGENTS.md / CLAUDE.md under these are not repo guidance: history,
# vendored payload, or the subject of a test. The prefix list mirrors
# scripts/sync-agent-files.sh EXCLUDE_PREFIXES; the component list generalises
# it to repos that are not this one.
NESTED_EXCLUDE_PREFIXES = ("sandbox_templates/skills/", "scripts/depaudit-fixtures/")
NESTED_EXCLUDE_PARTS = {"archive", "_archive", "node_modules", "vendor",
                        "third_party", "fixtures",
                        # payload stamped INTO other repos (a conventions
                        # template, a built plugin tree) — measured on the first
                        # real run: three false NESTED-AGENTS-NO-STUB hits.
                        # claude_init_files/ is the same shape, found 2026-09-12:
                        # a CLAUDE.md beside a Dockerfile, a compose file and an
                        # allowlist, i.e. a set for standing up ANOTHER machine,
                        # not guidance for the repo carrying it.
                        "templates", "dist", "claude_init_files"}

# Files whose contents get EXECUTED — by a shell, a task runner, CI, or an agent
# following instructions (an instruction file is an executable surface: the next
# agent does what it says). A venv name here is a live dependency; in any other
# file it is a mention.
EXEC_NAMES = {"justfile", "Justfile", "Makefile", "makefile", "Dockerfile",
              "AGENTS.md", "CLAUDE.md", "GEMINI.md", "SKILL.md", ".cursorrules",
              ".envrc", "tox.ini", "noxfile.py", "Taskfile.yml"}
EXEC_SUFFIXES = (".just", ".sh", ".bash", ".zsh", ".mk")
# Append-only records and ignore files: a venv name there is history or hygiene.
HISTORY_RE = re.compile(r"(^|/)(docs/adr|adr|work/archive|docs/_archive)/|(^|/)\.gitignore$")
# A PROJECT venv path: relative (optionally ./), never /root/.venv or $HOME/.venv.
PROJECT_VENV_BIN_RE = re.compile(r"(?:(?<![\w/~}$.])|(?<=\./))\.venv(?:-sandbox)?/bin/")

VENV_PATH_RE = re.compile(r"\.venv[\w.-]*/bin/")
# Host paths as seen from a container: here the agent home is /root, so ANY
# /home/… is the host's (macolima excepts /home/agent/, its container home).
HOST_PATH_RE = re.compile(r"/Volumes/|/Users/|/home/")
SCRIPT_TOKEN_RE = re.compile(r"(?:^|[\s*/])((?:[\w.-]+/)*[\w.-]+\.py)\b")
# Hard-coded venv names and OS-keyed selection in tracked files.
HARDCODE_GREP = (
    r"\.venv-linux|\.venv(-sandbox)?/bin/|os\(\) *== *\"(macos|linux)\""
    r"|UV_PROJECT_ENVIRONMENT"
)
EVIDENCE_CAP = 8


# --------------------------------------------------------------------------- #
# model
# --------------------------------------------------------------------------- #

@dataclass
class Finding:
    id: str
    level: str
    msg: str
    evidence: list[str] = field(default_factory=list)


@dataclass
class Repo:
    path: Path
    root_label: str
    kind: str           # "profile" | "host-only"
    rel: str
    findings: list[Finding] = field(default_factory=list)
    summary: dict[str, str] = field(default_factory=dict)

    def add(self, fid: str, level: str, msg: str, evidence=None) -> None:
        ev = list(evidence or [])
        extra = len(ev) - EVIDENCE_CAP
        if extra > 0:
            ev = ev[:EVIDENCE_CAP] + [f"… and {extra} more"]
        self.findings.append(Finding(fid, level, msg, ev))


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #

def git(repo: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", str(repo), "-c", "core.quotepath=off", *args],
        capture_output=True, text=True, check=False,
    )


def ignored(repo: Path, rel: str) -> bool:
    return git(repo, "check-ignore", "-q", "--", rel).returncode == 0


def dir_ignored(repo: Path, name: str) -> bool:
    """Is directory `name` ignored by the REPO's rules? An existing venv carries
    its own `.gitignore` containing `*`, and `check-ignore name/` matches that
    inner file — a false pass. Probe an existing dir WITHOUT the slash (git
    stats it as a directory; the inner file cannot match the dir itself), and a
    missing one WITH it (the slash is the only way to say "directory")."""
    return ignored(repo, name if (repo / name).is_dir() else name + "/")


def tracked_files(repo: Path) -> list[str]:
    r = git(repo, "ls-files", "-z")
    return [p for p in r.stdout.split("\0") if p] if r.returncode == 0 else []


def read(p: Path, limit: int = 1_000_000) -> str:
    try:
        with p.open("r", encoding="utf-8", errors="replace") as fh:
            return fh.read(limit)
    except OSError:
        return ""


def is_venv(d: Path) -> bool:
    return (d / "pyvenv.cfg").is_file()


def find_repos(root: Path, max_depth: int) -> list[Path]:
    """Every dir holding `.git` (dir or worktree file), descending into repos
    too — a channel repo like depot/ holds its members as gitignored nested
    checkouts. Hidden dirs, venvs and SKIP_DIRS are never entered."""
    found: list[Path] = []

    def walk(d: Path, depth: int) -> None:
        if (d / ".git").exists():
            found.append(d)
        if depth >= max_depth:
            return
        try:
            kids = sorted(p for p in d.iterdir()
                          if p.is_dir() and not p.is_symlink())
        except OSError:
            return
        for k in kids:
            if k.name.startswith(".") or k.name in SKIP_DIRS or is_venv(k):
                continue
            walk(k, depth + 1)

    walk(root, 0)
    return found


# --------------------------------------------------------------------------- #
# agent instruction files
# --------------------------------------------------------------------------- #

FENCE_RE = re.compile(r"^\s*(```|~~~).*?^\s*\1", re.M | re.S)
CODE_SPAN_RE = re.compile(r"`[^`\n]*`")
INLINE_IMPORT_RE = re.compile(r"(?<![\w@`])@(?:\./)?AGENTS\.md\b")


def claude_state(text: str) -> str:
    """absent handled by caller. stub | import+extra | substantive | empty.

    An `@AGENTS.md` import counts anywhere in a line ("See @AGENTS.md for …" is
    a stub), but not inside a code span or fenced block — Claude Code skips
    those when parsing imports (code.claude.com/docs/en/memory)."""
    live = CODE_SPAN_RE.sub("", FENCE_RE.sub("", text))
    lines = [l for l in live.splitlines() if l.strip()]
    if not lines:
        return "empty"
    imports = any(INLINE_IMPORT_RE.search(l) for l in lines)
    rest = [l for l in lines if not INLINE_IMPORT_RE.search(l)
            and not l.lstrip().startswith(("#", "<!--", "-->"))]
    if imports:
        return "stub" if len(rest) <= 2 else "import+extra"
    return "substantive"


def claude_file_state(root: Path, rel_dir: str = "") -> str | None:
    """None if absent. A CLAUDE.md symlinked to the AGENTS.md beside it is the
    other documented way to share one file — that is a stub, not a second
    source (reading through the link would see AGENTS.md's content)."""
    c = root / rel_dir / "CLAUDE.md"
    if not (c.is_file() or c.is_symlink()):
        return None
    if c.is_symlink():
        try:
            if c.resolve() == (root / rel_dir / "AGENTS.md").resolve():
                return "stub"
        except OSError:
            pass
    return claude_state(read(c))


def agent_pair(has_agents: bool, cstate: str | None) -> tuple[str | None, str, str]:
    """(flag, level, message) for one AGENTS.md / CLAUDE.md pair."""
    if has_agents:
        if cstate == "stub":
            return None, INFO, "AGENTS.md + CLAUDE.md stub"
        if cstate is None:
            return ("AGENTS-NO-STUB", ACTION,
                    "AGENTS.md without a CLAUDE.md importing it — Claude Code "
                    "does not read AGENTS.md natively")
        if cstate == "empty":
            return ("AGENTS-NO-STUB", ACTION, "CLAUDE.md is empty — add `@AGENTS.md`")
        if cstate == "import+extra":
            return ("BOTH-SUBSTANTIVE", ACTION,
                    "CLAUDE.md imports AGENTS.md but carries its own content too "
                    "— agy never sees that part")
        return ("BOTH-SUBSTANTIVE", ACTION,
                "AGENTS.md and a CLAUDE.md that does not import it — two "
                "sources of truth")
    if cstate in ("stub", "import+extra"):
        return ("BROKEN-IMPORT", ACTION, "CLAUDE.md imports an AGENTS.md that does not exist")
    if cstate == "substantive":
        return ("CLAUDE-ONLY", ACTION,
                "CLAUDE.md with no AGENTS.md — agy reads nothing; move the content "
                "to AGENTS.md and leave the stub")
    return ("NO-AGENT-FILES", INFO, "neither AGENTS.md nor CLAUDE.md")


def nested_excluded(rel_dir: str) -> bool:
    probe = rel_dir.rstrip("/") + "/"
    if any(probe.startswith(p) for p in NESTED_EXCLUDE_PREFIXES):
        return True
    return any(part in NESTED_EXCLUDE_PARTS or "fixture" in part
               for part in Path(rel_dir).parts)


def check_agents(r: Repo, files: list[str]) -> None:
    root = r.path
    has_agents = (root / "AGENTS.md").is_file()
    cfile = root / "CLAUDE.md"
    cstate = claude_file_state(root)
    flag, level, msg = agent_pair(has_agents, cstate)
    r.summary["agents"] = flag or "ok"
    if flag:
        r.add(flag, level, msg, ["CLAUDE.md"] if cfile.is_file() else [])
    for name in ("AGENTS.md", "CLAUDE.md"):
        if (root / name).is_file() and name not in files:
            state = "gitignored" if ignored(root, name) else "untracked"
            r.add(f"{name.split('.')[0]}-NOT-TRACKED", INFO,
                  f"{name} exists but is {state} — other clones and machines "
                  "do not get it")

    dirs: dict[str, set[str]] = {}
    for f in files:
        p = Path(f)
        if p.name in ("AGENTS.md", "CLAUDE.md") and len(p.parts) > 1:
            dirs.setdefault(str(p.parent), set()).add(p.name)
    for d, names in sorted(dirs.items()):
        if nested_excluded(d):
            continue
        cs = claude_file_state(root, d) if "CLAUDE.md" in names else None
        flag, level, msg = agent_pair("AGENTS.md" in names, cs)
        if flag and flag != "NO-AGENT-FILES":
            r.add(f"NESTED-{flag}", level, f"{d}/: {msg}", [d + "/"])


# --------------------------------------------------------------------------- #
# the sandbox notice
# --------------------------------------------------------------------------- #

# Any `managed by …` name matches: the neutral marker the sandbox writes today,
# and the two legacy ones (`macolima`, `windows-ai-sandbox`) it replaces once.
NOTICE_MARKER_RE = re.compile(r"^<!--\s*BEGIN sandbox-notice")
# GEMINI.md joins the pair check_agents enumerates BECAUSE agy reads it as a
# rules file — so a notice block lands there too. It is NOT half of the
# AGENTS-source / CLAUDE-stub pair (0009), which is why this check keeps its own
# enumeration instead of widening check_agents'.
NOTICE_NAMES = ("AGENTS.md", "CLAUDE.md", "GEMINI.md")


def check_notice(r: Repo, files: list[str]) -> None:
    """A sandbox-notice block inside a repo (ADR-0015).

    The notice belongs in each agent's GLOBAL home, where every `up` and
    `converge` regenerates it from one template. A copy inside a repo goes
    stale the moment the template moves, and the conventions rule forbids repo
    agents editing inside the markers — so it is unfixable from within the repo
    that carries it. Root files count whether tracked or not (an untracked one
    still briefs this clone's agents); nested ones only when tracked, since an
    untracked nested copy reaches nobody else."""
    root = r.path
    rels = [n for n in NOTICE_NAMES if (root / n).is_file()]
    rels += [f for f in files
             if Path(f).name in NOTICE_NAMES and len(Path(f).parts) > 1
             and not nested_excluded(str(Path(f).parent))]
    ev = []
    for rel in dict.fromkeys(rels):
        for i, line in enumerate(read(root / rel).splitlines(), 1):
            if NOTICE_MARKER_RE.match(line):
                ev.append(f"{rel}:{i}: {line.strip()}")
    r.summary["notice"] = "in repo" if ev else "—"
    if ev:
        r.add("NOTICE-IN-REPO", ACTION,
              "a sandbox-notice block inside a repo — the sandbox writes its "
              "notice into the agent homes (ADR-0015); strip it with "
              "`scripts/sync-agent-notice.sh --strip`", ev)


# --------------------------------------------------------------------------- #
# Claude Code settings
# --------------------------------------------------------------------------- #

def bash_inner(rule: str) -> str | None:
    m = re.fullmatch(r"\s*Bash\((.*)\)\s*", rule, re.S)
    return m.group(1) if m else None


def rule_regex(pattern: str) -> re.Pattern:
    """Claude Code Bash rule → regex over the whole command text.
    `:*` is only a suffix and equals a trailing ` *`; a trailing ` *` also
    matches the bare command; any other `*` matches any text
    (code.claude.com/docs/en/permissions.md, "Wildcard patterns"; the sentences
    this rests on are quoted in docs/permissions-model.md §"How a Bash rule
    matches")."""
    p = pattern
    if p.endswith(":*"):
        p = p[:-2] + " *"
    tail = ""
    if p.endswith(" *"):
        p, tail = p[:-2], r"(?: .*)?"
    body = ".*".join(re.escape(part) for part in p.split("*"))
    return re.compile("^" + body + tail + "$", re.S)


def spellings(script: str, repo: Path) -> list[str]:
    """Every way an agent plausibly runs `script`. Each gets a trailing arg so
    the check stays inside documented matching (no bare-command ambiguity)."""
    s = [
        f"python {script}", f"python3 {script}",
        f"uv run {script}", f"uv run python {script}", f"uv run python3 {script}",
        f"uv run --locked python {script}",
        f"{HOST_SLOT}/bin/python {script}", f"{HOST_SLOT}/bin/python3 {script}",
        f"{SANDBOX_SLOT}/bin/python {script}", f"{SANDBOX_SLOT}/bin/python3 {script}",
        f"./{HOST_SLOT}/bin/python {script}", f"./{SANDBOX_SLOT}/bin/python {script}",
    ]
    target = repo / script
    if target.is_file() and os.access(target, os.X_OK):
        s += [script, f"./{script}"]
    if (target.parent / "__init__.py").is_file():
        mod = script[:-3].replace("/", ".")
        s += [f"python -m {mod}", f"python3 -m {mod}"]
    return [x + " ARG" for x in s]


def check_settings(r: Repo, files: list[str]) -> None:
    fence: list[tuple[str, re.Pattern]] = []    # (source rule, regex) ask+deny
    scripts: dict[str, str] = {}                 # script -> first source
    present = []
    for name in (".claude/settings.json", ".claude/settings.local.json"):
        f = r.path / name
        if not f.is_file():
            continue
        where = "tracked" if name in files else (
            "gitignored" if ignored(r.path, name) else "untracked")
        present.append(f"{Path(name).name} ({where})")
        try:
            data = json.loads(read(f))
        except json.JSONDecodeError as e:
            r.add("SETTINGS-UNPARSED", UNKNOWN, f"{name}: not valid JSON ({e.msg})",
                  [f"{name}:{e.lineno}"])
            continue
        perms = data.get("permissions") or {}
        allow = [x for x in perms.get("allow") or [] if isinstance(x, str)]
        ask = [x for x in perms.get("ask") or [] if isinstance(x, str)]
        deny = [x for x in perms.get("deny") or [] if isinstance(x, str)]

        # A tracked settings file is shared policy — it has to work in every
        # environment. An untracked/gitignored one is this machine's
        # accumulated approvals: stale entries there are hygiene, not a defect.
        shared = where == "tracked"
        hits = [x for x in allow if VENV_PATH_RE.search(x)]
        if hits:
            r.add("VENV-PATH-ALLOW", ACTION if shared else INFO,
                  f"{name} ({where}): allow rules name a venv path — use the "
                  "`uv run …` form (one rule, every environment)", hits)
        # A shared allow rule on `.venv-linux` is the same stale-venv hazard as a
        # script pinned to it, so it counts toward the done-check too.
        linux = [x for x in allow if ".venv-linux" in x]
        if linux and shared:
            r.add("HARDCODED-VENV-LINUX", ACTION,
                  f"{name}: shared allow rules pinned to `.venv-linux` — use the "
                  "`uv run …` form", linux)

        hooks = data.get("hooks") or {}
        hook_cmds = []
        for event, entries in hooks.items() if isinstance(hooks, dict) else []:
            for entry in entries or []:
                for h in (entry.get("hooks") or []) if isinstance(entry, dict) else []:
                    if isinstance(h, dict) and h.get("command"):
                        hook_cmds.append(f"{event}: {h['command']}")
        if hook_cmds:
            r.add("REPO-HOOKS", INFO,
                  f"{name}: repo hooks (they stack on the sandbox's own)", hook_cmds)

        hp = [x for x in allow + ask + deny if HOST_PATH_RE.search(x)]
        hp += [c for c in hook_cmds if HOST_PATH_RE.search(c)]
        if hp:
            r.add("HOST-PATH", ACTION if (r.kind == "profile" and shared) else INFO,
                  f"{name} ({where}): rules/hooks name a host path — dead inside "
                  "a container", hp)

        if any(x.strip() in ("WebFetch", "WebFetch(*)") for x in allow):
            r.add("BARE-WEBFETCH", ACTION,
                  f"{name}: bare WebFetch allow — scope it with domain: "
                  "(docs/permissions-model.md)", ["WebFetch"])

        mode = perms.get("defaultMode")
        if mode == "bypassPermissions":
            r.add("BYPASS-MODE", ACTION, f"{name}: defaultMode bypassPermissions", [mode])
        elif mode:
            r.add("DEFAULT-MODE", INFO, f"{name}: defaultMode {mode}", [mode])

        for rule in ask + deny:
            inner = bash_inner(rule)
            if inner is None:
                continue
            fence.append((rule, rule_regex(inner)))
            for m in SCRIPT_TOKEN_RE.finditer(inner.replace("*", " ")):
                tok = m.group(1).lstrip("./") if m.group(1).startswith("./") else m.group(1)
                if "/bin/python" in tok or tok.startswith(".venv"):
                    continue
                scripts.setdefault(tok, name)

    r.summary["settings"] = ", ".join(present) or "—"
    for script, src in sorted(scripts.items()):
        missing = [sp[:-4] for sp in spellings(script, r.path)
                   if not any(rx.match(sp) for _, rx in fence)]
        if missing:
            r.add("ASK-GAP", ACTION,
                  f"{script}: fenced by ask/deny rules ({src}) but these spellings "
                  "match none — each falls through to the broad allow "
                  "(sandbox: python:*, uv run:*, auto mode)", missing)


# --------------------------------------------------------------------------- #
# Python environments
# --------------------------------------------------------------------------- #

def find_venvs(repo: Path, depth: int = 2) -> list[Path]:
    out: list[Path] = []

    def walk(d: Path, lvl: int) -> None:
        try:
            kids = sorted(p for p in d.iterdir() if p.is_dir() and not p.is_symlink())
        except OSError:
            return
        for k in kids:
            if is_venv(k):
                out.append(k)
            elif (lvl < depth and k.name not in SKIP_DIRS
                  and not k.name.startswith(".git")
                  and not (k / ".git").exists()):   # a nested repo reports its own
                walk(k, lvl + 1)

    walk(repo, 1)
    return out


def cfg(v: Path) -> dict[str, str]:
    d = {}
    for line in read(v / "pyvenv.cfg").splitlines():
        if "=" in line:
            k, _, val = line.partition("=")
            d[k.strip()] = val.strip()
    return d


def shebang_owner(v: Path) -> tuple[str | None, str]:
    """(owner, interpreter) from the first python console script in bin/."""
    b = v / "bin"
    try:
        entries = sorted(b.iterdir())
    except OSError:
        return None, ""
    for e in entries:
        if not e.is_file() or e.name.startswith(("activate", "python", "deactivate")):
            continue
        try:
            with e.open("rb") as fh:
                head = fh.read(256)
        except OSError:
            continue
        if not head.startswith(b"#!"):
            continue
        interp = head[2:].split(b"\n", 1)[0].decode("utf-8", "replace").strip()
        if "python" not in interp:
            continue
        if interp.startswith("/workspace/"):
            return "sandbox", interp
        if interp.startswith(("/Volumes/", "/Users/", "/home/")):
            return "host", interp
        return None, interp
    return None, ""


def venv_owner(v: Path) -> tuple[str, str]:
    """(host | sandbox | unknown, how)."""
    owner, interp = shebang_owner(v)
    if owner:
        return owner, f"shebang {interp}"
    home = cfg(v).get("home", "")
    if "/opt/uv/" in home or "-linux-" in home:
        return "sandbox", f"home {home}"
    if platform.system() == "Darwin":
        # macOS never makes a venv whose home is /usr/bin (Apple's python3
        # resolves into the CommandLineTools framework); Ubuntu's does.
        if home.rstrip("/") in ("/usr/bin", "/usr/local/bin"):
            return "sandbox", f"home {home} (Linux path on a Mac)"
        if home:
            return "host", f"home {home}"
    # On Linux, host and container can share /usr/bin/python3 — only a shebang
    # tells them apart, and this venv has no console script to read.
    return "unknown", f"home {home or '(none)'}; no console script to read"


def venv_empty(v: Path) -> bool:
    return not any(v.glob("lib/python*/site-packages/*.dist-info"))


def check_python(r: Repo, files: list[str]) -> None:
    root = r.path
    is_py = any((root / m).exists() for m in
                ("pyproject.toml", "uv.lock", "setup.py", "requirements.txt"))
    venvs = find_venvs(root)
    labels = []
    for v in venvs:
        rel = str(v.relative_to(root))
        slot = v.name
        owner, how = venv_owner(v)
        c = cfg(v)
        ver = c.get("version_info") or c.get("version") or "?"
        home = c.get("home", "")
        alive = bool(home) and Path(home).exists()
        tag = f"{rel} [{owner}, {ver}{'' if alive else ', dead here'}]"
        labels.append(tag)
        ev = [f"{rel}: {how}"]
        lvl = ACTION if r.kind == "profile" else INFO
        if owner == "unknown":
            r.add("VENV-OWNER-UNKNOWN", UNKNOWN,
                  f"{rel}: can't tell whether host or sandbox built it", ev)
        elif slot == HOST_SLOT and owner == "sandbox":
            r.add("SANDBOX-VENV-IN-HOST-SLOT", lvl,
                  f"{rel}: built by a sandbox but sitting in the host's slot — "
                  "retire after .venv-sandbox is built (plan Phase F)", ev)
        elif slot == SANDBOX_SLOT and owner == "host":
            r.add("HOST-VENV-IN-SANDBOX-SLOT", ACTION,
                  f"{rel}: built by a host in the sandbox's slot", ev)
        if slot.startswith(".venv-") and slot != SANDBOX_SLOT:
            r.add("LEGACY-VENV-SLOT", lvl,
                  f"{rel}: venv slot the rule retires — rebuild as .venv-sandbox "
                  "(sandbox) or .venv (host), never rename", ev)
        if slot not in (HOST_SLOT, SANDBOX_SLOT) and not slot.startswith(".venv-"):
            r.add("OTHER-VENV", INFO, f"{rel}: venv outside the named slots", ev)
        if owner == "host" and not alive:
            r.add("DEAD-HOST-VENV", INFO,
                  f"{rel}: host venv whose interpreter is gone ({home})", ev)
        if venv_empty(v):
            r.add("EMPTY-VENV", INFO, f"{rel}: no packages installed", ev)
    r.summary["venvs"] = "; ".join(labels) or "—"

    if not is_py:
        r.summary["python"] = "not a Python project"
        return

    if not dir_ignored(root, SANDBOX_SLOT):
        r.add("NO-VENV-SANDBOX-IGNORE", ACTION,
              "`.venv-sandbox/` is not gitignored — add `.venv*/`", [".gitignore"])
    if not dir_ignored(root, HOST_SLOT):
        r.add("NO-VENV-IGNORE", ACTION, "`.venv/` is not gitignored", [".gitignore"])

    pv = root / ".python-version"
    if not pv.is_file():
        r.add("NO-PYTHON-VERSION", ACTION if r.kind == "profile" else INFO,
              "no .python-version — host and sandbox may pick different minors")
        r.summary["python"] = "unpinned"
    else:
        val = read(pv).strip().splitlines()[0].strip() if read(pv).strip() else ""
        r.summary["python"] = f".python-version {val}"
        if ".python-version" not in files:
            r.add("PYTHON-VERSION-UNTRACKED", ACTION,
                  f".python-version ({val}) is not tracked", [".python-version"])
        if r.kind == "profile" and not val.startswith(BAKED_PYTHONS):
            r.add("PYTHON-VERSION-UNBAKED", ACTION,
                  f".python-version {val} — the sandbox images bake only "
                  f"{', '.join(BAKED_PYTHONS)}; it cannot resolve offline", [".python-version"])

    g = git(root, "grep", "-n", "-I", "-E", HARDCODE_GREP, "--", ".",
            ":(exclude,glob)**/archive/**", ":(exclude,glob)**/_archive/**",
            ":(exclude,glob)**/*fixtures*/**", ":(exclude,glob)**/.venv*/**")
    linux, linux_doc, osel, code, mention, upe = [], [], [], [], [], []
    for line in g.stdout.splitlines():
        path = line.split(":", 1)[0]
        if path.startswith(".claude/settings"):
            continue    # judged by check_settings, tier-aware
        if HISTORY_RE.search(path):
            continue    # append-only records and ignore files
        text = line.split(":", 2)[-1]
        name = Path(path).name
        executed = (name in EXEC_NAMES or name.endswith(EXEC_SUFFIXES)
                    or path.startswith(".github/workflows/"))
        if "UV_PROJECT_ENVIRONMENT" in text:
            upe.append(line)
        if ".venv-linux" in text:
            (linux if executed else linux_doc).append(line)
        if re.search(r"os\(\) *== *\"(macos|linux)\"", text):
            osel.append(line)
        elif PROJECT_VENV_BIN_RE.search(text):
            (code if executed else mention).append(line)
    if linux:
        r.add("HARDCODED-VENV-LINUX", ACTION,
              "`.venv-linux` in a file that is executed or followed (script, "
              "justfile, CI, agent instructions) — `uv run …`, or a path "
              "derived from UV_PROJECT_ENVIRONMENT with .venv as the fallback", linux)
    if linux_doc:
        r.add("DOC-VENV-LINUX", ACTION,
              "`.venv-linux` in live docs — `uv run …`", linux_doc)
    if osel:
        r.add("OS-VENV-SELECT", ACTION,
              "venv chosen by OS — a Linux host and a Linux sandbox are both "
              "'linux'; read UV_PROJECT_ENVIRONMENT instead", osel)
    if code:
        r.add("VENV-PATH-IN-CODE", ACTION,
              "project venv path in a file that is executed or followed — "
              "`uv run …`, or derive from UV_PROJECT_ENVIRONMENT with .venv as "
              "the fallback", code)
    if mention:
        r.add("VENV-PATH-MENTION", INFO,
              "project venv path mentioned (docstring, README, config) — correct "
              "on a host; prefer `uv run …` when next edited", mention)
    if upe:
        r.add("READS-UV-PROJECT-ENVIRONMENT", INFO,
              "references UV_PROJECT_ENVIRONMENT (check it reads the variable, "
              "never sets it)", upe)

    envrc = root / ".envrc"
    if envrc.is_file() and "UV_PROJECT_ENVIRONMENT" in read(envrc):
        r.add("ENVRC-UPE", ACTION,
              ".envrc sets UV_PROJECT_ENVIRONMENT — on a host that must stay unset",
              [".envrc"])


# --------------------------------------------------------------------------- #
# machine-local files
# --------------------------------------------------------------------------- #

def check_local(r: Repo, files: list[str]) -> None:
    miss = [shape for shape, probe in (("*.local", "zz-workspace-scan-probe.local"),
                                       ("*.local.*", "zz-workspace-scan-probe.local.md"))
            if not ignored(r.path, probe)]
    if miss:
        r.add("NO-LOCAL-IGNORE", ACTION,
              "`.local` files are not ignored in shape(s): " + ", ".join(miss),
              [".gitignore"])
    # `*.local.example*` is the sanctioned committed form (the convention's
    # `!*.local.example*` negation): an example of a local file, for every clone.
    t = [f for f in files if re.search(r"\.local($|\.)", Path(f).name)
         and ".local.example" not in Path(f).name]
    if t:
        r.add("TRACKED-LOCAL", ACTION,
              "machine-local files already committed — ignoring them won't untrack "
              "them; each needs a decision", t)
    r.summary["local"] = "ok" if not miss else "missing " + ", ".join(miss)


# --------------------------------------------------------------------------- #
# roots, report
# --------------------------------------------------------------------------- #

def load_roots(args) -> list[tuple[Path, str, str]]:
    roots: list[tuple[Path, str, str]] = []
    pdir = Path(args.profiles_dir)
    if pdir.is_dir():
        for p in sorted(x for x in pdir.iterdir() if x.is_dir() and not x.name.startswith(".")):
            ws = Path(args.workspaces_root) / p.name
            roots.append((ws, p.name, "profile"))
    extra = list(args.also or [])
    if not args.also and ROOTS_FILE.is_file():
        for line in read(ROOTS_FILE).splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                extra.append(line)
    for e in extra:
        pe = Path(e).expanduser()
        roots.append((pe, f"host:{pe.name}", "host-only"))
    return roots


def scan(args) -> tuple[list[Repo], list[str]]:
    repos: list[Repo] = []
    notes: list[str] = []
    seen: set[Path] = set()
    for root, label, kind in load_roots(args):
        if not root.is_dir():
            notes.append(f"{label}: {root} does not exist — skipped")
            continue
        for rp in find_repos(root, args.max_depth):
            rp = rp.resolve()
            if rp in seen:
                continue
            seen.add(rp)
            rel = str(rp.relative_to(root.resolve())) if rp != root.resolve() else "."
            r = Repo(rp, label, kind, rel)
            files = tracked_files(rp)
            check_agents(r, files)
            check_notice(r, files)
            check_settings(r, files)
            check_python(r, files)
            check_local(r, files)
            repos.append(r)
    return repos, notes


def render_md(repos: list[Repo], notes: list[str], args) -> str:
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    out = [f"# workspace-scan — {now}", "",
           "Generated by `scripts/workspace-scan.py`. **Local only — names every "
           "repo in every profile; never commit.**", ""]
    counts: dict[str, list[str]] = {}
    for r in repos:
        for f in r.findings:
            if f.level != INFO:
                counts.setdefault(f"{f.level} {f.id}", []).append(f"{r.root_label}/{r.rel}")
    out += ["## Summary", "", f"{len(repos)} repos. Findings needing action or "
            "unresolved (INFO omitted):", "",
            "| Level / ID | Repos | Which |", "|---|---|---|"]
    for k in sorted(counts):
        uniq = sorted(set(counts[k]))
        out.append(f"| {k} | {len(uniq)} | {', '.join(uniq)} |")
    if not counts:
        out.append("| — | 0 | — |")
    for n in notes:
        out.append(f"\n> {n}")
    by_root: dict[str, list[Repo]] = {}
    for r in repos:
        by_root.setdefault(r.root_label, []).append(r)
    for label, rs in by_root.items():
        out += ["", f"## {label} ({rs[0].kind})", "",
                "| Repo | Agents | Notice | Settings | Python | Venvs | Local |",
                "|---|---|---|---|---|---|---|"]
        for r in rs:
            s = r.summary
            out.append(f"| {r.rel} | {s.get('agents','')} | {s.get('notice','')} | "
                       f"{s.get('settings','')} | "
                       f"{s.get('python','')} | {s.get('venvs','')} | {s.get('local','')} |")
        for r in rs:
            fs = [f for f in r.findings if args.verbose or f.level != INFO]
            if not fs:
                continue
            out += ["", f"### {label}/{r.rel}", ""]
            for f in fs:
                out.append(f"- **{f.level} {f.id}** — {f.msg}")
                for e in f.evidence:
                    out.append(f"  - `{e}`")
    return "\n".join(out) + "\n"


def render_json(repos: list[Repo], notes: list[str]) -> str:
    return json.dumps({
        "generated": datetime.datetime.now().isoformat(timespec="seconds"),
        "notes": notes,
        "repos": [{
            "path": str(r.path), "root": r.root_label, "kind": r.kind, "rel": r.rel,
            "summary": r.summary,
            "findings": [f.__dict__ for f in r.findings],
        } for r in repos],
    }, indent=2) + "\n"


def out_allowed(path: Path) -> tuple[bool, str]:
    parent = path.parent
    top = subprocess.run(["git", "-C", str(parent), "rev-parse", "--show-toplevel"],
                         capture_output=True, text=True, check=False)
    if top.returncode != 0:
        return True, ""
    rc = subprocess.run(["git", "-C", str(parent), "check-ignore", "-q", "--", str(path)],
                        capture_output=True, text=True, check=False).returncode
    if rc == 0:
        return True, ""
    return False, (f"{path} is inside the git work tree {top.stdout.strip()} and is "
                   "NOT ignored — the report names every repo in every profile. "
                   "Use a *.local / *.local.* name there, or a path outside the repo.")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--profiles-dir", default=str(DEFAULT_PROFILES_DIR))
    ap.add_argument("--workspaces-root", default=str(DEFAULT_WORKSPACES_ROOT))
    ap.add_argument("--also", action="append", metavar="DIR",
                    help="host-only root (repeatable); overrides .workspace-scan.local")
    ap.add_argument("--max-depth", type=int, default=4)
    ap.add_argument("--format", choices=("md", "json"), default="md")
    ap.add_argument("--out", metavar="FILE")
    ap.add_argument("--verbose", action="store_true", help="include INFO in md details")
    ap.add_argument("--fail-on", default="", metavar="ID[,ID...]",
                    help="exit 1 if any ACTION/UNKNOWN finding has one of these IDs")
    args = ap.parse_args(argv)

    if args.out:
        ok, why = out_allowed(Path(args.out).resolve())
        if not ok:
            print(f"workspace-scan: refusing --out: {why}", file=sys.stderr)
            return 2

    repos, notes = scan(args)
    text = render_json(repos, notes) if args.format == "json" else render_md(repos, notes, args)
    if args.out:
        p = Path(args.out)
        p.write_text(text, encoding="utf-8")
        p.chmod(0o600)
        print(f"workspace-scan: {len(repos)} repos → {p}", file=sys.stderr)
    else:
        sys.stdout.write(text)

    gate = {x.strip() for x in args.fail_on.split(",") if x.strip()}
    if gate and any(f.id in gate and f.level != INFO for r in repos for f in r.findings):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
