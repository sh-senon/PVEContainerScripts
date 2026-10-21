#!/usr/bin/env python3
"""Read-only relationship discovery for the Obsi Markdown vault."""
import argparse
import collections
import json
import re
from pathlib import Path

ROOT_DEFAULT = "/srv/obsi-ai"
TOP = ("Work", "Homelab")
LINK = re.compile(r"!?(?:\\[\\[)([^]\\n]+)\\]\\]")
MAX_NOTES = 2000
MAX_BYTES = 256 * 1024


def discover(root: Path):
    root = root.resolve()
    if not root.is_dir() or not (root / ".obsi-storage-check").is_file():
        raise ValueError("Vault safety marker missing")
    docs = []
    for env in TOP:
        base = root / env
        if base.is_symlink() or not base.is_dir():
            continue
        for path in sorted(base.rglob("*.md")):
            if len(docs) >= MAX_NOTES:
                raise ValueError("Too many notes for relationship scan")
            if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root):
                continue
            if path.stat().st_size > MAX_BYTES:
                continue
            try:
                body = path.read_text(encoding="utf-8")
            except (UnicodeError, OSError):
                continue
            if "This note has moved to **[[" in body and len(body) < 600:
                continue
            docs.append({"path": path.relative_to(root).as_posix(),
                         "name": path.stem, "env": env, "body": body})
    indexed = {d["path"].removesuffix(".md").lower(): d for d in docs}
    by_name = collections.defaultdict(list)
    for d in docs:
        by_name[(d["env"], d["name"].lower())].append(d)
    confirmed = []
    suggestions = []
    seen = set()
    for d in docs:
        explicit = set()
        for match in LINK.finditer(d["body"]):
            target = match.group(1).split("|", 1)[0].split("#", 1)[0].strip()
            if target.startswith("Attachments/") or not target:
                continue
            item = indexed.get(target.removesuffix(".md").lower())
            if item is None and "/" not in target:
                options = by_name.get((d["env"], target.removesuffix(".md").lower()), [])
                if len(options) == 1:
                    item = options[0]
            if item and item["env"] == d["env"] and item["path"] != d["path"]:
                key = (d["path"], item["path"])
                if key not in seen:
                    confirmed.append({"source": d["path"], "target": item["path"],
                                      "evidence": "existing_wikilink"})
                    seen.add(key)
                explicit.add(item["path"])
        # Candidates are exact title mentions, not proof of dependencies.
        # Restrict to same environment; do not ship note content outside the vault.
        for other in docs:
            if other["env"] != d["env"] or other["path"] == d["path"] or other["path"] in explicit:
                continue
            if len(other["name"]) < 5:
                continue
            if re.search(r"(?<![\\w])" + re.escape(other["name"]) + r"(?![\\w])",
                         d["body"], flags=re.I):
                key = (d["path"], other["path"])
                if key not in seen:
                    suggestions.append({"source": d["path"], "target": other["path"],
                                        "evidence": "exact_note_title_mention",
                                        "confidence": "candidate_only",
                                        "action": "review text and propose qualified wikilink if relevant"})
                    seen.add(key)
    return {"mode": "read_only", "notes_checked": len(docs),
            "confirmed_links": confirmed[:250],
            "link_suggestions": suggestions[:250],
            "truncated": len(confirmed) > 250 or len(suggestions) > 250,
            "rules": ["Work and Homelab are never cross-linked automatically",
                      "Exact title mentions are candidates, not verified technical relationships",
                      "No files were modified or sent to external AI services",
                      "Existing notes require explicit approval before adding any link"]}


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--root", default=ROOT_DEFAULT)
    print(json.dumps(discover(Path(p.parse_args().root)), indent=2, ensure_ascii=False))
