from __future__ import annotations

import os
import re
from dataclasses import dataclass, field


@dataclass
class AllowlistEntry:
    raw_line: str
    domain: str = ""
    is_commented: bool = False
    block_tag: str = ""


class ConfigIO:
    def __init__(self, repo_root: str) -> None:
        self.allowlist_path = os.path.join(repo_root, "proxy", "allowed_domains.txt")

    def read_allowed_domains(self) -> list[AllowlistEntry]:
        entries: list[AllowlistEntry] = []
        current_tag = ""

        with open(self.allowlist_path) as f:
            for line in f:
                raw = line.rstrip("\n")

                tag_match = re.search(r"\[([a-z-]+)\]", raw)
                if tag_match and "---" in raw:
                    current_tag = tag_match.group(1)
                    entries.append(AllowlistEntry(raw_line=raw, block_tag=current_tag))
                    continue

                if raw.strip() == "":
                    current_tag_before = current_tag
                    entries.append(AllowlistEntry(raw_line=raw))
                    continue

                if raw.startswith("# ===") or raw.startswith("# ---"):
                    entries.append(AllowlistEntry(raw_line=raw))
                    continue

                if raw.startswith("# #"):
                    entries.append(AllowlistEntry(raw_line=raw))
                    continue

                if raw.startswith("#") and current_tag:
                    stripped = raw.lstrip("# ").strip()
                    if stripped and not stripped.startswith("=") and not stripped.startswith("-"):
                        looks_like_domain = re.match(
                            r"^\.?[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$",
                            stripped,
                        )
                        if looks_like_domain:
                            entries.append(AllowlistEntry(
                                raw_line=raw, domain=stripped,
                                is_commented=True, block_tag=current_tag,
                            ))
                            continue

                if raw.startswith("#"):
                    entries.append(AllowlistEntry(raw_line=raw))
                    continue

                domain = raw.strip()
                if domain:
                    entries.append(AllowlistEntry(
                        raw_line=raw, domain=domain,
                        is_commented=False, block_tag=current_tag,
                    ))
                else:
                    entries.append(AllowlistEntry(raw_line=raw))

        return entries

    def write_allowed_domains(self, entries: list[AllowlistEntry]) -> None:
        lines: list[str] = []
        for entry in entries:
            if entry.domain:
                prefix = "# " if entry.is_commented else ""
                lines.append(f"{prefix}{entry.domain}")
            else:
                lines.append(entry.raw_line)

        with open(self.allowlist_path, "w") as f:
            f.write("\n".join(lines) + "\n")

    def add_domain(
        self, domain: str, block_tag: str | None = None
    ) -> None:
        entries = self.read_allowed_domains()

        new_entry = AllowlistEntry(
            raw_line=domain, domain=domain,
            is_commented=False, block_tag=block_tag or "",
        )

        if block_tag:
            insert_idx = None
            for i, e in enumerate(entries):
                if e.block_tag == block_tag:
                    insert_idx = i
            if insert_idx is not None:
                entries.insert(insert_idx + 1, new_entry)
            else:
                entries.append(new_entry)
        else:
            entries.append(new_entry)

        self.write_allowed_domains(entries)
