"""Translate portal file results and notification images for one bus caller"""

from __future__ import annotations

import asyncio
import os
import re
import sys
from dataclasses import dataclass, field
from collections.abc import AsyncIterator
from pathlib import Path
from uuid import uuid4

from boltons.cacheutils import LRI
from jeepney import HeaderFields as H, Message, MessageFlag, MessageType

from .protocol import (
    CHOOSER,
    MAX_REQUESTS,
    NOTIFICATIONS,
    PORTAL,
    PORTAL_PATH,
    REQUEST,
    matches,
)
from resources import Namespace, local_file_uri

NO_REPLY_EXPECTED = int(MessageFlag.no_reply_expected)
CHOOSER_MODES = frozendict(
    {"OpenFile": "read", "SaveFile": "save", "SaveFiles": "save"}
)


@dataclass
class ChooserCall:
    mode: str
    path: str
    no_reply: bool = False
    closing: set[str] = field(default_factory=set)
    cancelled: bool = False


def notification_path(value: str) -> Path | None:
    if value.casefold().startswith("file:"):
        return local_file_uri(value)[0]
    if Path(value).is_absolute():
        return Path(value)
    if "/" in value or ":" in value:
        raise ValueError("expected an icon theme name or local file URI")
    return None


class FilePortalRelay:
    def __init__(self, namespace: Namespace | None) -> None:
        self.namespace = namespace
        self.pending: dict[int, ChooserCall] = {}
        self.handles: dict[tuple[str, str], ChooserCall] = {}
        self.early: list[tuple[bytes, Message]] = []
        self.closed = LRI(max_size=MAX_REQUESTS)

    async def notification(self, message: Message) -> bool:
        body = list(message.body)
        hints = dict(body[6])
        changed = False
        for key in ("image-path", "image_path", "app_icon"):
            value = (
                body[2] if key == "app_icon" else hints.get(key, ("s", ""))[1]
            )
            if not isinstance(value, str) or not value:
                continue
            try:
                path = notification_path(value)
                if path is None:
                    continue
                if self.namespace is None:
                    raise ValueError("the caller's filesystem is unavailable")
                try:
                    mapped = self.namespace.host_uri(path.as_uri())
                except OSError, ValueError:
                    # Keep app_icon separate from image-data: notification
                    # servers may show both, with distinct image priorities
                    if key == "app_icon":
                        mapped = await self.namespace.notification_icon(value)
                    elif (
                        "image-data" not in hints and "image_data" not in hints
                    ):
                        hints["image-data"] = (
                            "(iiibiiay)",
                            self.namespace.notification_image(value),
                        )
                        mapped = ""
                    else:
                        raise
                if key == "app_icon":
                    body[2] = mapped
                elif mapped:
                    hints[key] = ("s", mapped)
                else:
                    hints.pop(key, None)
            except (ImportError, OSError, ValueError, TimeoutError) as error:
                print(
                    f"WARNING: Notification {key} unavailable: {error}",
                    file=sys.stderr,
                )
                if key == "app_icon":
                    body[2] = ""
                else:
                    hints.pop(key, None)
            changed = True
        if changed:
            body[6] = hints
            message.body = tuple(body)
        return changed

    async def outgoing(
        self, message: Message, unique_name: str | None = None
    ) -> bool:
        fields = message.header.fields
        if message.header.message_type != MessageType.method_call:
            return False
        interface = fields.get(H.interface)
        member = fields.get(H.member)
        if matches(
            message,
            interface=NOTIFICATIONS,
            member="Notify",
            signature="susssasa{sv}i",
        ):
            return await self.notification(message)
        if interface == REQUEST and member == "Close" and not message.body:
            path = fields.get(H.path)
            destination = fields.get(H.destination)
            if destination == PORTAL or str(destination).startswith(":"):
                for call in self.pending.values():
                    if call.path == path:
                        call.closing.add(destination)
            for key, call in list(self.handles.items()):
                if key[1] == path and destination in (PORTAL, key[0]):
                    call.cancelled = True
                    self.handles.pop(key)
                    self.closed[key] = None
            return False
        if (
            not matches(
                message,
                interface=CHOOSER,
                path=PORTAL_PATH,
                signature="ssa{sv}",
            )
            or member not in CHOOSER_MODES
        ):
            return False
        if self.namespace is None:
            raise ValueError(
                "the caller's filesystem is unavailable for file selection"
            )
        if unique_name is None:
            raise ValueError("the file chooser caller has no bus unique name")
        if len(self.pending) + len(self.handles) >= MAX_REQUESTS:
            raise ValueError("too many outstanding file chooser requests")
        options = dict(message.body[2])
        token = options.get("handle_token", ("s", uuid4().hex))
        if token[0] != "s" or not re.fullmatch(r"[A-Za-z0-9_]+", token[1]):
            raise ValueError("invalid file chooser handle token")
        changed = "handle_token" not in options
        options["handle_token"] = token
        no_reply = bool(message.header.flags & NO_REPLY_EXPECTED)
        if no_reply:
            # Resolve the real request handle and owner even when the caller
            # only wants Response. Suppress this internal return on the way back
            message.header.flags &= ~NO_REPLY_EXPECTED
            changed = True
        mode = CHOOSER_MODES[member]
        for key in ("current_folder", "current_file"):
            if key not in options:
                continue
            try:
                signature, value = options[key]
                if (
                    signature != "ay"
                    or not value.endswith(b"\0")
                    or b"\0" in value[:-1]
                ):
                    raise ValueError("invalid file chooser path hint")
                path = self.namespace.host_path(
                    Path(os.fsdecode(value[:-1])),
                    save=mode == "save" and key == "current_file",
                )
                options[key] = ("ay", os.fsencode(path) + b"\0")
            except (OSError, ValueError) as error:
                options.pop(key)
                print(
                    f"WARNING: File chooser {key} omitted: {error}",
                    file=sys.stderr,
                )
            changed = True
        if mode == "read" and options.get("writable") == ("b", True):
            mode = "write"
        self.pending[message.header.serial] = ChooserCall(
            mode,
            f"{PORTAL_PATH}/request/{unique_name[1:].replace('.', '_')}/{token[1]}",
            no_reply=no_reply,
        )
        if changed:
            message.body = (*message.body[:2], options)
        return changed

    async def response(
        self, message: Message, call: ChooserCall
    ) -> bytes | None:
        if call.cancelled:
            return None
        if message.header.fields.get(H.signature) != "ua{sv}":
            raise ValueError("invalid file chooser response signature")
        if message.body[0] == 0:
            try:
                if self.namespace is None:
                    raise ValueError("the caller's filesystem is unavailable")
                results = dict(message.body[1])
                signature, uris = results.get("uris", ("as", []))
                if signature != "as" or not uris or len(uris) > 256:
                    raise ValueError("invalid file chooser URI list")
                async with asyncio.timeout(10):
                    mapped = [
                        await self.namespace.guest_uri(uri, mode=call.mode)
                        for uri in uris
                    ]
                results["uris"] = ("as", mapped)
                message.body = (0, results)
            except (OSError, ValueError, TimeoutError) as error:
                print(
                    f"WARNING: File chooser selection unavailable: {error}",
                    file=sys.stderr,
                )
                message.body = (2, {})
        return None if call.cancelled else message.serialise()

    async def incoming(
        self, data: bytes, message: Message
    ) -> AsyncIterator[bytes]:
        fields = message.header.fields
        request = (
            self.pending.pop(fields.get(H.reply_serial), None)
            if message.header.message_type
            in (MessageType.method_return, MessageType.error)
            else None
        )
        if request is not None:
            if message.header.message_type == MessageType.method_return:
                if fields.get(H.signature) != "o" or len(message.body) != 1:
                    raise ValueError("invalid file chooser request handle")
                key = (fields.get(H.sender), message.body[0])
                self.closed.pop(key, None)
                if PORTAL in request.closing or key[0] in request.closing:
                    self.closed[key] = None
                else:
                    self.handles[key] = request
            if not request.no_reply:
                yield data
            buffered, self.early = self.early, []
            for raw, response in buffered:
                async for chunk in self.incoming(raw, response):
                    yield chunk
            return
        if matches(
            message, type="signal", interface=REQUEST, member="Response"
        ):
            key = (fields.get(H.sender), fields.get(H.path))
            if key in self.closed:
                self.closed.pop(key)
                return
            call = self.handles.get(key)
            if call is not None:
                try:
                    transformed = await self.response(message, call)
                finally:
                    if self.handles.get(key) is call:
                        self.handles.pop(key)
                if transformed is not None:
                    yield transformed
                return
            if any(call.path == key[1] for call in self.pending.values()):
                if len(self.early) >= MAX_REQUESTS:
                    raise ValueError("too many early portal response signals")
                self.early.append((data, message))
                return
        yield data
