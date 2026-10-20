"""
title: Obsi Hybrid Vault Writer
author: Obsi
version: 1.0.0
description: Creates new TrueNAS Markdown notes automatically; asks before editing existing notes.
"""

import base64
import difflib
import json
import re
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


class Tools:
    WRITE_URL = "http://127.0.0.1:18767/write"
    TOKEN_FILE = Path("/etc/obsi-write-token")
    MAX_IMAGE = 10 * 1024 * 1024
    UPLOAD_ROOT = Path("/var/lib/obsi-webui/uploads")

    @classmethod
    def _request(cls, operation, **kwargs):
        secret = cls.TOKEN_FILE.read_text(encoding="ascii").strip()
        payload = json.dumps({"operation": operation, **kwargs}).encode("utf-8")
        request = Request(cls.WRITE_URL, data=payload, method="POST",
                          headers={"Authorization": "Bearer " + secret,
                                   "Content-Type": "application/json"})
        try:
            with urlopen(request, timeout=35) as response:
                return json.loads(response.read(1024 * 1024))
        except HTTPError as error:
            try:
                result = json.loads(error.read(8192))
                raise ValueError(result.get("error", "Write rejected")) from None
            except json.JSONDecodeError:
                raise ValueError("Knowledge service rejected the request") from None
        except (URLError, TimeoutError):
            raise ValueError("Knowledge service unavailable. Nothing has been confirmed saved.") from None

    @staticmethod
    def _approved(answer):
        return answer is True or (isinstance(answer, dict)
                                  and answer.get("confirmed") is True
                                  and not answer.get("error"))

    @staticmethod
    def _diff(before, after, path):
        lines = list(difflib.unified_diff(
            before.splitlines(keepends=True), after.splitlines(keepends=True),
            fromfile=path + " (existing)", tofile=path + " (proposed)"))
        preview = "".join(lines)
        if len(preview) > 18000:
            raise ValueError("Change is too large for safe inline review. Split it into smaller edits.")
        return preview or "(No content changes)"

    async def create_new_note(self, path: str, content: str) -> str:
        """
        Automatically create a NEW Obsidian Markdown note, including missing folders.
        Never overwrites an existing note. For existing notes use propose_note_update.

        :param path: Vault-relative .md path, e.g. Hardware/AceMagic AM18.md
        :param content: Full UTF-8 Markdown text for the new note.
        """
        result = self._request("create_note", path=path, content=content)
        return f"Saved NEW note: {result['path']} (TrueNAS)."

    async def propose_note_update(self, path: str, revised_content: str,
                                  __event_call__=None, __metadata__=None) -> str:
        """
        Propose replacing the complete content of an EXISTING Markdown note.
        The user MUST approve an inline diff before any write. If refused or
        interrupted, the file is unchanged.

        :param path: Existing vault-relative .md path.
        :param revised_content: Entire proposed new content, preserving unchanged sections.
        """
        original = self._request("inspect", path=path)
        if not original["exists"]:
            return "Note does not exist. Use create_new_note instead."
        preview = self._diff(original["content"], revised_content, path)
        if preview == "(No content changes)":
            return "No changes required."
        if __event_call__ is None or (isinstance(__metadata__, dict) and
                                      (__metadata__.get("internal") or not __metadata__.get("session_id"))):
            return "No live confirmation dialog available. Existing note NOT modified."
        answer = await __event_call__({
            "type": "confirmation",
            "data": {"title": "Approve Obsi note update?",
                     "message": "Review the complete diff below. Approve only if correct.\n\n" + preview}
        })
        if not self._approved(answer):
            return "Update rejected or confirmation unavailable. Note unchanged."
        result = self._request("update_note", path=path, content=revised_content,
                               expected_sha256=original["sha256"])
        return f"Approved update saved: {result['path']}."

    @classmethod
    def _images(cls, metadata, files, user):
        candidates = []
        # Images pasted into chat arrive in the most recent user message.
        latest = (metadata or {}).get("user_message") or {}
        contents = latest.get("content", []) if isinstance(latest, dict) else []
        if not isinstance(contents, list):
            contents = []
        for block in contents:
            if not isinstance(block, dict) or block.get("type") != "image_url":
                continue
            image_url = block.get("image_url", {})
            uri = image_url.get("url") if isinstance(image_url, dict) else image_url
            if isinstance(uri, str) and uri.startswith("data:image/") and ";base64," in uri[:90]:
                encoded = uri.split(";base64,", 1)[1]
                if len(encoded) > cls.MAX_IMAGE * 2:
                    continue
                try:
                    raw = base64.b64decode(encoded, validate=True)
                except (ValueError, base64.binascii.Error):
                    continue
                if len(raw) <= cls.MAX_IMAGE:
                    candidates.append(raw)
        # Files explicitly attached through the uploader live in local storage.
        for item in files or []:
            entry = item.get("file", {}) if isinstance(item, dict) else {}
            if not isinstance(entry, dict):
                continue
            if entry.get("user_id") != (user or {}).get("id"):
                continue
            p = entry.get("path", "")
            if not isinstance(p, str):
                continue
            original = Path(p)
            if original.is_symlink():
                continue
            resolved = original.resolve(strict=False)
            if not resolved.is_relative_to(cls.UPLOAD_ROOT.resolve(strict=False)):
                continue
            if not resolved.is_file() or resolved.stat().st_size > cls.MAX_IMAGE:
                continue
            raw = resolved.read_bytes()
            if raw.startswith((b"\x89PNG\r\n\x1a\n", b"\xff\xd8\xff", b"GIF87a", b"GIF89a")) or (
                    len(raw) >= 12 and raw[:4] == b"RIFF" and raw[8:12] == b"WEBP"):
                candidates.append(raw)
        return candidates

    async def save_screenshot_to_note(
        self, path: str, description: str = "", image_index: int = 0,
        __metadata__=None, __files__=None, __user__=None, __event_call__=None,
    ) -> str:
        """
        Save the ORIGINAL user-uploaded screenshot in TrueNAS/Attachments, and
        embed it into an Obsidian Markdown note. A NEW note is created automatically.
        If the note already exists, the user must approve the addition in chat.
        Works only when an original image is present in the current chat turn.

        :param path: Markdown note path to create or add the screenshot to.
        :param description: Brief factual description of the screenshot.
        :param image_index: Zero-based index of an image uploaded in this user turn.
        """
        images = self._images(__metadata__, __files__, __user__)
        if not images:
            return ("I cannot access original screenshot bytes in this tool call. "
                    "Please paste or upload the image in the same chat message as the request.")
        if not 0 <= image_index < len(images):
            return f"Image index out of range; {len(images)} available."
        existing = self._request("inspect", path=path)
        expected = existing["sha256"] if existing["exists"] else None
        if existing["exists"]:
            if __event_call__ is None or (isinstance(__metadata__, dict) and
                                          (__metadata__.get("internal") or not __metadata__.get("session_id"))):
                return "Screenshot not saved: existing note requires a live approval dialog."
            answer = await __event_call__({
                "type": "confirmation",
                "data": {"title": "Add screenshot to existing note?",
                         "message": f"Note: {path}\n\nDescription: {description}\n\n"
                                    "The original image will be stored in Attachments/ and a new embed appended."}
            })
            if not self._approved(answer):
                return "Screenshot import rejected. No files changed."
        result = self._request(
            "screenshot_note", path=path, description=description,
            image_base64=base64.b64encode(images[image_index]).decode("ascii"),
            expected_sha256=expected,
        )
        return (f"Saved original screenshot: {result['attachment']}\n"
                f"{result['status'].capitalize()} note: {result['path']}\n"
                f"Obsidian embed: {result['embed']}")
