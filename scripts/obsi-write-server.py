#!/usr/bin/env python3
"""Obsi vault write service. Bound to loopback behind an authenticated SSH tunnel."""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import re
import tempfile
import threading
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path, PurePosixPath

ROOT = Path("/srv/obsi-ai")
TOKEN_FILE = Path("/etc/obsi-write-token")
MAX_NOTE = 256 * 1024
MAX_IMAGE = 10 * 1024 * 1024
MAX_REQUEST = 15 * 1024 * 1024
MAX_RESPONSE = 15 * 1024 * 1024
GUARD = threading.RLock()


def mounted() -> None:
    if not ROOT.is_mount() or not (ROOT / ".obsi-storage-check").is_file():
        raise RuntimeError("TrueNAS mount or safety marker missing. No writes allowed.")


def vault_path(name: str, *, suffix: str = ".md") -> Path:
    if not isinstance(name, str) or not 1 <= len(name) <= 220:
        raise ValueError("Invalid path length")
    if "\\" in name or name.startswith("/") or name.endswith("/"):
        raise ValueError("Must use vault-relative POSIX paths")
    parts = PurePosixPath(name).parts
    if not parts or any(p in ("", ".", "..") or p.startswith(".") or ":" in p for p in parts):
        raise ValueError("Hidden, parent and special paths are forbidden")
    if len(parts) > 8 or len(name.encode("utf-8")) > 240:
        raise ValueError("Path is too deep or too long")
    if not name.lower().endswith(suffix):
        raise ValueError("Expected " + suffix)
    path = ROOT
    for part in parts:
        path = path / part
        if path.is_symlink():
            raise ValueError("Symlinks are forbidden")
    if not path.resolve(strict=False).is_relative_to(ROOT.resolve(strict=True)):
        raise ValueError("Outside vault")
    return path


def ensure_parent(path: Path) -> None:
    cur = ROOT
    for part in path.relative_to(ROOT).parts[:-1]:
        cur = cur / part
        if cur.is_symlink():
            raise ValueError("Symlinked directory forbidden")
        if not cur.exists():
            cur.mkdir(mode=0o770)
        if not cur.is_dir():
            raise ValueError("Parent is not a directory")


def get_content(path: Path) -> tuple[str | None, str | None]:
    if not path.exists():
        return None, None
    if not path.is_file() or path.is_symlink() or path.stat().st_size > MAX_NOTE:
        raise ValueError("Note is not a supported regular Markdown file")
    raw = path.read_bytes()
    try:
        value = raw.decode("utf-8")
    except UnicodeError as exc:
        raise ValueError("Note is not UTF-8") from exc
    return value, hashlib.sha256(raw).hexdigest()


def note_bytes(content: str) -> bytes:
    if not isinstance(content, str):
        raise ValueError("Content must be text")
    raw = content.encode("utf-8")
    if not raw or len(raw) > MAX_NOTE:
        raise ValueError("Note must contain 1 to 262144 bytes")
    return raw


def exclusive_create(path: Path, raw: bytes) -> None:
    ensure_parent(path)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags, 0o660)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        path.unlink(missing_ok=True)
        raise


def replace_if_unchanged(path: Path, raw: bytes, expected: str) -> None:
    before, current_hash = get_content(path)
    if before is None:
        raise ValueError("Note no longer exists")
    if not isinstance(expected, str) or not hmac.compare_digest(current_hash, expected):
        raise ValueError("Note changed since approval; review again")
    fd, tmp = tempfile.mkstemp(prefix=".obsi-", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(tmp, 0o660)
        os.replace(tmp, path)
    finally:
        Path(tmp).unlink(missing_ok=True)


def decode_image(encoded: str) -> tuple[bytes, str]:
    if not isinstance(encoded, str) or len(encoded) > MAX_IMAGE * 2:
        raise ValueError("Invalid image data")
    raw = base64.b64decode(encoded, validate=True)
    if not 1 <= len(raw) <= MAX_IMAGE:
        raise ValueError("Image exceeds 10 MiB")
    if raw.startswith(b"\x89PNG\r\n\x1a\n"):
        ext = ".png"
    elif raw.startswith(b"\xff\xd8\xff"):
        ext = ".jpg"
    elif raw.startswith((b"GIF87a", b"GIF89a")):
        ext = ".gif"
    elif len(raw) >= 12 and raw[:4] == b"RIFF" and raw[8:12] == b"WEBP":
        ext = ".webp"
    else:
        raise ValueError("Only PNG, JPEG, GIF and WebP screenshots are supported")
    return raw, ext


def dispatch(data: dict) -> dict:
    mounted()
    if not isinstance(data, dict):
        raise ValueError("JSON object required")
    op = data.get("operation")
    with GUARD:
        if op == "read_image":
            name = data.get("path")
            if not isinstance(name, str) or not name.startswith("Attachments/"):
                raise ValueError("Only vault Attachments images are readable")
            ext = Path(name).suffix.lower()
            if ext not in (".png", ".jpg", ".jpeg", ".gif", ".webp"):
                raise ValueError("Unsupported attachment type")
            path = vault_path(name, suffix=ext)
            if not path.is_file() or path.is_symlink():
                raise ValueError("Image not found")
            if not 0 < path.stat().st_size <= MAX_IMAGE:
                raise ValueError("Invalid attachment size")
            raw = path.read_bytes()
            if ext == ".png" and not raw.startswith(b"\\x89PNG\\r\\n\\x1a\\n"):
                raise ValueError("Invalid PNG")
            if ext in (".jpg", ".jpeg") and not raw.startswith(b"\\xff\\xd8\\xff"):
                raise ValueError("Invalid JPEG")
            if ext == ".gif" and not raw.startswith((b"GIF87a", b"GIF89a")):
                raise ValueError("Invalid GIF")
            if ext == ".webp" and not (len(raw) >= 12 and raw[:4] == b"RIFF" and raw[8:12] == b"WEBP"):
                raise ValueError("Invalid WebP")
            return {"path": name, "image_base64": base64.b64encode(raw).decode("ascii")}
        if op == "inspect":
            path = vault_path(data.get("path"))
            content, digest = get_content(path)
            return {"exists": content is not None, "content": content, "sha256": digest}
        if op == "create_note":
            path = vault_path(data.get("path"))
            exclusive_create(path, note_bytes(data.get("content")))
            return {"status": "created", "path": str(path.relative_to(ROOT))}
        if op == "update_note":
            path = vault_path(data.get("path"))
            replace_if_unchanged(path, note_bytes(data.get("content")), data.get("expected_sha256"))
            return {"status": "updated", "path": str(path.relative_to(ROOT))}
        if op == "screenshot_note":
            path = vault_path(data.get("path"))
            description = data.get("description")
            if not isinstance(description, str) or len(description) > 8000:
                raise ValueError("Invalid screenshot description")
            raw, ext = decode_image(data.get("image_base64"))
            current, digest = get_content(path)
            if current is not None:
                expected = data.get("expected_sha256")
                if not isinstance(expected, str) or not hmac.compare_digest(digest, expected):
                    raise ValueError("Existing note requires a fresh approved revision")
            elif data.get("expected_sha256") is not None:
                raise ValueError("Note disappeared since approval")
            attachments = ROOT / "Attachments"
            if attachments.is_symlink():
                raise ValueError("Unsafe attachment directory")
            attachments.mkdir(mode=0o770, exist_ok=True)
            name = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:12] + ext
            image_path = vault_path("Attachments/" + name, suffix=ext)
            embed = "![[Attachments/" + name + "]]"
            section = "\n\n## Screenshot\n\n" + (description.strip() + "\n\n" if description.strip() else "") + embed + "\n"
            if current is None:
                title = path.stem.replace("_", " ").replace("-", " ")
                updated = "# " + title + section
            else:
                updated = current.rstrip() + section
            note_raw = note_bytes(updated)
            exclusive_create(image_path, raw)
            try:
                if current is None:
                    exclusive_create(path, note_raw)
                else:
                    replace_if_unchanged(path, note_raw, digest)
            except BaseException:
                image_path.unlink(missing_ok=True)
                raise
            return {"status": "updated" if current is not None else "created", "path": str(path.relative_to(ROOT)),
                    "attachment": str(image_path.relative_to(ROOT)), "embed": embed}
        raise ValueError("Unknown operation")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_error(404)

    def do_POST(self):
        if self.path != "/write":
            self.send_error(404)
            return
        token = TOKEN_FILE.read_text(encoding="ascii").strip()
        supplied = self.headers.get("Authorization", "")
        if not hmac.compare_digest(supplied, "Bearer " + token):
            self.send_error(401)
            return
        try:
            n = int(self.headers.get("Content-Length", "0"))
            if not 0 < n <= MAX_REQUEST:
                raise ValueError("Request size invalid")
            data = json.loads(self.rfile.read(n))
            result = dispatch(data)
            code = 200
        except (ValueError, UnicodeError, json.JSONDecodeError) as exc:
            result, code = {"error": str(exc)}, 409
        except Exception:
            self.log_error("Write service failed; check journal")
            result, code = {"error": "Internal write failure; no success confirmed"}, 500
        raw = json.dumps(result).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


if __name__ == "__main__":
    mounted()
    ThreadingHTTPServer(("127.0.0.1", 8767), Handler).serve_forever()
