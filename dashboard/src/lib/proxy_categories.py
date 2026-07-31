"""Purpose-based grouping for allowlist block tags.

Categories are a dashboard-only view concern — they don't exist in
`allowed_domains.txt` itself (which is organized by lifecycle tier, not
purpose). Add new tags to CATEGORY_TAGS as blocks are added; anything
unmapped falls into "Other" rather than raising, since a forgotten mapping
shouldn't break the page.

Colors are the first 5 slots of the validated categorical palette
(dataviz skill, references/palette.md) in fixed order — never cycled or
reassigned per render.
"""

from __future__ import annotations

CATEGORY_TAGS: dict[str, list[str]] = {
    "AI / LLM CLIs & APIs": [
        "claude", "openrouter", "openai", "antigravity", "antigravity-install",
    ],
    "Dev tooling & docs": [
        "git", "vscode", "blender", "blender-community", "google-fonts",
        "playwright-install", "quarto-install", "beads-install",
    ],
    "Package & OS registries": [
        "pypi", "pytorch", "npm", "nvidia", "apt",
    ],
    "Academic & research data": [
        "citation-tools", "grants-gov", "numerai", "kaggle",
    ],
    "Productivity & Google Workspace": [
        "clickup", "google-workspace",
    ],
}

CATEGORY_ORDER: list[str] = list(CATEGORY_TAGS.keys()) + ["Other"]

CATEGORY_COLORS: dict[str, dict[str, str]] = {
    "AI / LLM CLIs & APIs":              {"light": "#2a78d6", "dark": "#3987e5"},
    "Dev tooling & docs":                {"light": "#eb6834", "dark": "#d95926"},
    "Package & OS registries":           {"light": "#1baf7a", "dark": "#199e70"},
    "Academic & research data":          {"light": "#eda100", "dark": "#c98500"},
    "Productivity & Google Workspace":   {"light": "#e87ba4", "dark": "#d55181"},
    "Other":                             {"light": "#898781", "dark": "#898781"},
}

CATEGORY_SLUGS: dict[str, str] = {
    "AI / LLM CLIs & APIs": "ai",
    "Dev tooling & docs": "dev",
    "Package & OS registries": "pkg",
    "Academic & research data": "research",
    "Productivity & Google Workspace": "productivity",
    "Other": "other",
}

TAG_CATEGORY: dict[str, str] = {
    tag: category
    for category, tags in CATEGORY_TAGS.items()
    for tag in tags
}


def category_for(tag: str) -> str:
    return TAG_CATEGORY.get(tag, "Other")


def color_var(tag: str) -> str:
    """CSS var() reference for a tag's category accent color."""
    slug = CATEGORY_SLUGS[category_for(tag)]
    return f"var(--cat-{slug})"


def css_vars_block() -> str:
    """<style> block declaring one CSS var per category, light + dark."""
    light = "\n".join(
        f"  --cat-{CATEGORY_SLUGS[cat]}: {colors['light']};"
        for cat, colors in CATEGORY_COLORS.items()
    )
    dark = "\n".join(
        f"  --cat-{CATEGORY_SLUGS[cat]}: {colors['dark']};"
        for cat, colors in CATEGORY_COLORS.items()
    )
    return (
        f"<style>\n"
        f":root {{\n{light}\n}}\n"
        f"@media (prefers-color-scheme: dark) {{\n"
        f"  :root {{\n{dark}\n  }}\n"
        f"}}\n"
        f"</style>"
    )
