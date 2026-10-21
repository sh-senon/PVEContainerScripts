"""
title: Obsi Hybrid Vault Writer
author: Obsi
version: 1.5.0
description: Creates new TrueNAS Markdown notes automatically; asks before editing existing notes.
"""

import base64
import difflib
import json
import re
import uuid
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


class Tools:
    WRITE_URL = "http://127.0.0.1:18767/write"
    TOKEN_FILE = Path("/etc/obsi-write-token")
    MAX_IMAGE = 10 * 1024 * 1024
    UPLOAD_ROOT = Path("/var/lib/obsi-webui/uploads")
    FILE_ID_RE = re.compile(r"(?<![0-9a-fA-F])[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}(?![0-9a-fA-F])")

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

    @staticmethod
    def _is_image(raw):
        return bool(raw) and (raw.startswith((b"\x89PNG\r\n\x1a\n", b"\xff\xd8\xff", b"GIF87a", b"GIF89a"))
                or (len(raw) >= 12 and raw[:4] == b"RIFF" and raw[8:12] == b"WEBP"))

    @classmethod
    async def _images(cls, metadata, files, user):
        """Resolve images from the CURRENT message only; verify ownership in Open WebUI DB."""
        from open_webui.models.files import Files

        metadata = metadata if isinstance(metadata, dict) else {}
        user_id = (user or {}).get("id")
        if not user_id:
            return []
        latest = metadata.get("user_message")
        candidates = []
        referenced_ids = []

        def add_reference(value):
            if isinstance(value, str):
                match = cls.FILE_ID_RE.search(value)
                if match:
                    referenced_ids.append(match.group().lower())

        # Preserve inline images when Open WebUI supplies base64 pixels.
        blocks = latest.get("content", []) if isinstance(latest, dict) else []
        for block in blocks if isinstance(blocks, list) else []:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "image_url":
                image_url = block.get("image_url", {})
                uri = image_url.get("url") if isinstance(image_url, dict) else image_url
                if isinstance(uri, str) and uri.startswith("data:image/") and ";base64," in uri[:90]:
                    encoded = uri.split(";base64,", 1)[1]
                    if len(encoded) <= cls.MAX_IMAGE * 2:
                        try:
                            raw = base64.b64decode(encoded, validate=True)
                            if len(raw) <= cls.MAX_IMAGE and cls._is_image(raw):
                                candidates.append(raw)
                        except (ValueError, base64.binascii.Error):
                            pass
                else:
                    add_reference(uri)
            elif block.get("type") in ("file", "image"):
                add_reference(block.get("id"))
                add_reference(block.get("url"))

        # Open WebUI may send uploaded images as file IDs or URL references.
        # Never resolve IDs mentioned in prose or from older chat messages.
        attached = []
        for source in (files, metadata.get("files"), latest.get("files") if isinstance(latest, dict) else None):
            if isinstance(source, list):
                attached.extend(source)
        for item in attached:
            if not isinstance(item, dict):
                continue
            entry = item.get("file")
            if isinstance(entry, dict):
                add_reference(entry.get("id"))
            add_reference(item.get("id"))
            add_reference(item.get("url"))

        for file_id in dict.fromkeys(referenced_ids):
            file_record = await Files.get_file_by_id_and_user_id(file_id, user_id)
            if file_record is None or not isinstance(file_record.path, str):
                continue
            original = Path(file_record.path)
            if original.is_symlink():
                continue
            resolved = original.resolve(strict=False)
            if not resolved.is_relative_to(cls.UPLOAD_ROOT.resolve(strict=False)):
                continue
            if not resolved.name.lower().startswith(file_id + "_"):
                continue
            if not resolved.is_file() or resolved.stat().st_size > cls.MAX_IMAGE:
                continue
            raw = resolved.read_bytes()
            if cls._is_image(raw):
                candidates.append(raw)
        return candidates

    async def view_saved_screenshot(self, attachment_path: str, __user__=None) -> str:
        """
        Display an existing TrueNAS image in chat via Open WebUI's authenticated file API.
        Only files inside the vault Attachments/ directory are supported.

        :param attachment_path: Vault relative screenshot path, e.g. Attachments/20261020-160352-481abc45080e.png
        """
        from open_webui.models.files import Files, FileForm

        user_id = (__user__ or {}).get("id")
        if not user_id:
            return "Screenshot not displayed: no authenticated Open WebUI user."
        if not isinstance(attachment_path, str) or not attachment_path.startswith("Attachments/"):
            return "Screenshot not displayed: expected an Attachments/ image path."

        secret = self.TOKEN_FILE.read_text(encoding="ascii").strip()
        request = Request(
            self.WRITE_URL,
            data=json.dumps({"operation": "read_image", "path": attachment_path}).encode("utf-8"),
            method="POST",
            headers={"Authorization": "Bearer " + secret, "Content-Type": "application/json"},
        )
        try:
            with urlopen(request, timeout=40) as response:
                payload = response.read(15 * 1024 * 1024 + 1)
            if len(payload) > 15 * 1024 * 1024:
                return "Screenshot too large to display."
            result = json.loads(payload)
            raw = base64.b64decode(result["image_base64"], validate=True)
        except HTTPError as error:
            return f"Screenshot unavailable (knowledge server HTTP {error.code})."
        except (URLError, TimeoutError, KeyError, ValueError, json.JSONDecodeError):
            return "Screenshot retrieval failed. No copy was created."

        if len(raw) > self.MAX_IMAGE or not self._is_image(raw):
            return "Invalid or oversized image returned by knowledge server."
        ext = Path(attachment_path).suffix.lower()
        if ext not in (".png", ".jpg", ".jpeg", ".gif", ".webp"):
            return "Unsupported image extension."
        file_id = str(uuid.uuid4())
        filename = file_id + "_obsi-view" + ext
        destination = self.UPLOAD_ROOT / filename
        destination.parent.mkdir(parents=True, exist_ok=True)
        try:
            with destination.open("xb") as output:
                output.write(raw)
            destination.chmod(0o600)
            file_record = await Files.insert_new_file(
                user_id,
                FileForm(
                    id=file_id,
                    filename="obsi-view" + ext,
                    path=str(destination),
                    data={"status": "completed"},
                    meta={"name": "obsi-view" + ext,
                          "content_type": "image/jpeg" if ext in (".jpg", ".jpeg") else "image/" + ("webp" if ext == ".webp" else ext[1:]),
                          "size": len(raw)},
                ),
            )
            if file_record is None:
                raise ValueError("Could not register image")
        except Exception:
            destination.unlink(missing_ok=True)
            return "Could not register screenshot with Open WebUI. Nothing displayed."
        image_url = "/api/v1/files/" + file_id + "/content"
        return (f"Screenshot retrieved from {attachment_path}.\n"
                f"Display using this exact Markdown, without altering the URL:\n"
                f"![Saved Obsi screenshot]({image_url})")

    async def save_screenshot_to_note(
        self, path: str, description: str = "", image_index: int = 0, label: str = "Technical screenshot",
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
        :param label: Short descriptive heading, e.g. pve03 node overview, not a generic Screenshot label.
        """
        images = await self._images(__metadata__, __files__, __user__)
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
                         "message": f"Note: {path}\n\nHeading: {label}\nDescription: {description}\n\n"
                                    "The original image will be stored in Attachments/ and a new embed appended."}
            })
            if not self._approved(answer):
                return "Screenshot import rejected. No files changed."
        result = self._request(
            "screenshot_note", path=path, description=description,
            image_base64=base64.b64encode(images[image_index]).decode("ascii"),
            label=label,
            expected_sha256=expected,
        )
        return (f"Saved original screenshot: {result['attachment']}\n"
                f"{result['status'].capitalize()} note: {result['path']}\n"
                f"Obsidian embed: {result['embed']}")

    def audit_knowledge_base(self) -> str:
        """
        Run a read-only audit of the Obsi vault. Identify redirect notes,
        potential duplicates, unresolved links and missing metadata.
        Do not modify, merge, move or delete any notes.
        """
        report = self._request("audit_knowledge_base")
        if report.get("mode") != "read_only":
            return "Audit failed: backend did not confirm read-only mode."
        return json.dumps(report, ensure_ascii=False, indent=2)
