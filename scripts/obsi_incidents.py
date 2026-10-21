#!/usr/bin/env python3
"""Obsi incident memory: read-only incident search over Work/ and Homelab/."""
import argparse
import json
import re
from pathlib import Path

ROOT = Path("/srv/obsi-ai")
MAX_NOTES = 2000
MAX_BYTES = 256 * 1024
STOP = {"the", "and", "for", "with", "from", "this", "that", "issue", "problem", "error", "what", "when", "have", "were", "are", "und", "der", "die", "das", "bei", "ein", "eine", "ist", "nicht"}


def words(value):
    return {s for s in re.findall(r"[a-z0-9][a-z0-9._-]{2,}", value.casefold()) if s not in STOP}


def frontmatter(text):
    if not text.startswith("---\n"):
        return {}
    end = text.find("\n---", 4)
    if end < 0:
        return {}
    result = {}
    for line in text[4:end].splitlines():
        if ":" in line and not line.startswith((" ", "\t")):
            key, value = line.split(":", 1)
            if key.strip() in {"type", "status", "environment", "last-updated", "last-verified", "resolution-status"}:
                result[key.strip()] = value.strip().strip('"').strip("'")
    return result


def search(root, query, environment="Work", limit=8):
    root = root.resolve()
    if not root.is_dir() or not (root / ".obsi-storage-check").is_file():
        raise ValueError("Vault marker missing")
    if environment not in ("Work", "Homelab"):
        raise ValueError("Select Work or Homelab explicitly")
    if not isinstance(query, str) or not 2 <= len(query) <= 500:
        raise ValueError("Query must be 2 to 500 characters")
    if not isinstance(limit, int) or not 1 <= limit <= 15:
        raise ValueError("Invalid result limit")
    folder = root / environment
    if folder.is_symlink():
        raise ValueError("Unsafe environment folder")
    if not folder.is_dir():
        return {"mode": "read_only", "environment": environment, "notes_checked": 0, "matches": []}
    needle = words(query)
    ranked = []
    checked = 0
    for path in sorted(folder.rglob("*.md")):
        if checked >= MAX_NOTES:
            break
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root):
            continue
        if path.stat().st_size > MAX_BYTES:
            continue
        checked += 1
        try:
            content = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            continue
        meta = frontmatter(content)
        title_words = words(path.stem)
        contents = words(content)
        overlap = needle & contents
        if not overlap:
            continue
        score = len(overlap) + 3 * len(needle & title_words)
        is_incident = meta.get("type", "").casefold() in ("incident", "problem", "troubleshooting")
        if is_incident:
            score += 2
        if "# Resolution" in content or "## Resolution" in content:
            score += 1
        # Only paths and metadata are returned. Retrieve complete notes with read_note,
        # where the user/model can evaluate if a fix was actually verified.
        ranked.append((score, {"path": path.relative_to(root).as_posix(),
                               "matched_terms": sorted(overlap)[:12],
                               "metadata": meta,
                               "incident_note": is_incident,
                               "score": score}))
    ranked.sort(key=lambda r: (-r[0], r[1]["path"]))
    return {"mode": "read_only", "environment": environment, "notes_checked": checked,
            "matches": [item for _, item in ranked[:limit]],
            "limitations": ["Keyword search is not semantic similarity or a guarantee of relevance",
                            "Only user-selected environment is searched",
                            "Resolution must be checked in the note before calling it verified"]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=str(ROOT))
    parser.add_argument("--environment", choices=("Work", "Homelab"), default="Work")
    parser.add_argument("--query", required=True)
    print(json.dumps(search(Path(parser.parse_args().root), parser.parse_args().query,
                            parser.parse_args().environment), ensure_ascii=False, indent=2))
