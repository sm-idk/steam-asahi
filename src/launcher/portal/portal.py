"""Route guest Steam portal URIs without changing the caller's bus identity"""

from __future__ import annotations

import asyncio
import re
import struct
import sys
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass
from functools import partial
from typing import TYPE_CHECKING
from uuid import uuid4

from aiotools import TaskScope

from jeepney import (
    DBusAddress,
    HeaderFields,
    Message,
    MessageFlag,
    MessageType,
    new_error,
    new_method_call,
    new_method_return,
    new_signal,
)
from jeepney.low_level import calc_msg_size

from desktop import send_steam_uri_async
from .files import FilePortalRelay
from .protocol import (
    MAX_MESSAGE_BYTES,
    MAX_REQUESTS,
    OPEN_URI,
    PORTAL,
    PORTAL_PATH,
    REQUEST,
    SCREENCAST,
    matches,
)

if TYPE_CHECKING:
    from resources import Namespace

NO_REPLY_EXPECTED = int(MessageFlag.no_reply_expected)


@dataclass
class MessageStream:
    receive: Callable[[], Awaitable[tuple[bytes, Message]]]
    send: Callable[[bytes], Awaitable[None]]
    send_eof: Callable[[], Awaitable[None]]

    @classmethod
    def from_streams(cls, reader, writer) -> MessageStream:
        async def send(data: bytes) -> None:
            writer.write(data)
            await writer.drain()

        async def send_eof() -> None:
            if writer.can_write_eof():
                writer.write_eof()
                await writer.drain()

        return cls(partial(read_message, reader), send, send_eof)


def descriptor_operation(message: Message) -> str | None:
    destination = message.header.fields.get(HeaderFields.destination, "")
    if not matches(message, type="method_call", path=PORTAL_PATH) or not (
        destination == PORTAL or destination.startswith(":")
    ):
        return None
    if matches(
        message,
        interface=SCREENCAST,
        member="OpenPipeWireRemote",
        signature="oa{sv}",
    ):
        return "pipewire"
    if matches(
        message, interface=OPEN_URI, signature="sha{sv}"
    ) and message.header.fields.get(HeaderFields.member) in (
        "OpenFile",
        "OpenDirectory",
    ):
        return "shared-file"
    return None


def steam_request_path(message: Message, unique_name: str) -> str:
    token = message.body[2].get("handle_token", ("s", uuid4().hex))
    if token[0] != "s" or not re.fullmatch(r"[A-Za-z0-9_]+", token[1]):
        raise ValueError("invalid portal handle token")
    return (
        f"{PORTAL_PATH}/request/{unique_name[1:].replace('.', '_')}/{token[1]}"
    )


def decode_message(data: bytes, descriptors: Sequence[int] = ()) -> Message:
    if len(data) < 16 or data[:1] not in (b"l", b"B") or data[3] != 1:
        raise ValueError("invalid D-Bus message header")
    size = calc_msg_size(data[:16])
    if not 16 <= size <= MAX_MESSAGE_BYTES or len(data) != size:
        raise ValueError("D-Bus message exceeds the protocol size limit")
    try:
        message = Message.from_buffer(data, fds=descriptors)
    except (
        AssertionError,
        IndexError,
        KeyError,
        RecursionError,
        struct.error,
        TypeError,
        UnicodeError,
    ) as error:
        raise ValueError("malformed D-Bus message") from error
    for field in (
        HeaderFields.path,
        HeaderFields.interface,
        HeaderFields.member,
        HeaderFields.error_name,
        HeaderFields.destination,
        HeaderFields.sender,
        HeaderFields.signature,
    ):
        if field in message.header.fields and not isinstance(
            message.header.fields[field], str
        ):
            raise ValueError("D-Bus string header has the wrong type")
    for field in (HeaderFields.reply_serial, HeaderFields.unix_fds):
        if field in message.header.fields and (
            type(message.header.fields[field]) is not int
            or not 0 <= message.header.fields[field] <= 0xFFFFFFFF
        ):
            raise ValueError("D-Bus integer header has the wrong type")
    if message.header.fields.get(HeaderFields.unix_fds, 0) != len(descriptors):
        raise ValueError("D-Bus descriptor count does not match its resources")
    return message


async def read_message(reader: asyncio.StreamReader) -> tuple[bytes, Message]:
    header = await reader.readexactly(16)
    if header[:1] not in (b"l", b"B") or header[3] != 1:
        raise ValueError("invalid D-Bus message header")
    size = calc_msg_size(header)
    if not 16 <= size <= MAX_MESSAGE_BYTES:
        raise ValueError("D-Bus message exceeds the protocol size limit")
    data = header + await reader.readexactly(size - 16)
    return data, decode_message(data)


async def relay_portal_messages(
    local: MessageStream,
    remote: MessageStream,
    *,
    caller_pid: int | None = None,
    namespace: Namespace | None = None,
) -> None:
    # Keep one upstream connection per caller: portal sessions, notification
    # IDs, match rules, and unicast signals belong to its original unique name
    pending: dict[int, Message] = {}
    pending_paths: dict[str, int] = {}
    pending_closes: dict[int, list[Message]] = {}
    requests: dict[str, tuple[str, asyncio.Task]] = {}
    unique_name: str | None = None
    serial = 0xF0000000
    client_closed = False
    files = FilePortalRelay(namespace)

    async def send(message: Message, sender: str | None = None) -> None:
        nonlocal serial
        serial = (serial + 1) % 0xFFFFFFFF or 1
        if sender is not None:
            message.header.fields[HeaderFields.sender] = sender
        await local.send(message.serialise(serial=serial))

    async def complete(path: str, uri: str, sender: str) -> None:
        try:
            status = await send_steam_uri_async(uri)
            response = new_signal(
                DBusAddress(path, interface=REQUEST),
                "Response",
                "ua{sv}",
                (0 if status == 0 else 2, {}),
            )
            response.header.fields[HeaderFields.destination] = unique_name
            await send(response, sender)
        except ConnectionError:
            pass
        finally:
            current = requests.get(path)
            if current is not None and current[1] is asyncio.current_task():
                requests.pop(path)

    async def outgoing() -> None:
        while True:
            data, message = await local.receive()
            fields = message.header.fields
            try:
                if await files.outgoing(message, unique_name):
                    data = message.serialise()
            except (OSError, ValueError) as error:
                if not message.header.flags & NO_REPLY_EXPECTED:
                    await send(
                        new_error(
                            message,
                            "org.freedesktop.DBus.Error.NotSupported",
                            "s",
                            (str(error),),
                        )
                    )
                continue
            if message.header.message_type == MessageType.method_call:
                path = fields.get(HeaderFields.path)
                if (
                    path in pending_paths
                    and (
                        fields.get(HeaderFields.destination) == PORTAL
                        or str(
                            fields.get(HeaderFields.destination, "")
                        ).startswith(":")
                    )
                    and fields.get(HeaderFields.interface) == REQUEST
                    and fields.get(HeaderFields.member) == "Close"
                    and not message.body
                ):
                    closes = pending_closes.setdefault(pending_paths[path], [])
                    if len(closes) >= MAX_REQUESTS:
                        raise ValueError("too many pending portal close calls")
                    closes.append(message)
                    continue
                if (
                    path in requests
                    and fields.get(HeaderFields.destination)
                    in (PORTAL, requests[path][0])
                    and fields.get(HeaderFields.interface) == REQUEST
                    and fields.get(HeaderFields.member) == "Close"
                    and not message.body
                ):
                    sender, task = requests.pop(path)
                    task.cancel()
                    await asyncio.gather(task, return_exceptions=True)
                    if not message.header.flags & NO_REPLY_EXPECTED:
                        await send(new_method_return(message), sender)
                    continue
                if (
                    (
                        fields.get(HeaderFields.destination) == PORTAL
                        or str(
                            fields.get(HeaderFields.destination, "")
                        ).startswith(":")
                    )
                    and path == PORTAL_PATH
                    and fields.get(HeaderFields.interface) == OPEN_URI
                    and fields.get(HeaderFields.member) == "OpenURI"
                    and fields.get(HeaderFields.signature) == "ssa{sv}"
                    and len(message.body) == 3
                    and message.body[1].partition(":")[0].casefold()
                    in ("steam", "steamlink")
                ):
                    if len(pending) + len(requests) >= MAX_REQUESTS:
                        if not message.header.flags & NO_REPLY_EXPECTED:
                            await send(
                                new_error(
                                    message,
                                    "org.freedesktop.DBus.Error.LimitsExceeded",
                                )
                            )
                        continue
                    if unique_name is not None:
                        try:
                            predicted = steam_request_path(message, unique_name)
                            if (
                                predicted in pending_paths
                                or predicted in requests
                            ):
                                raise ValueError(
                                    "portal handle token is in use"
                                )
                        except ValueError:
                            if not message.header.flags & NO_REPLY_EXPECTED:
                                await send(
                                    new_error(
                                        message,
                                        "org.freedesktop.DBus.Error.InvalidArgs",
                                    )
                                )
                            continue
                        # Keep an automatically generated token stable while
                        # the version query is in flight
                        if "handle_token" not in message.body[2]:
                            message.body[2]["handle_token"] = (
                                "s",
                                predicted.rsplit("/", 1)[1],
                            )
                        pending_paths[predicted] = message.header.serial
                    pending[message.header.serial] = message
                    # Ask the real portal for its interface version using the
                    # same serial. Its reply establishes the live portal owner
                    # without ever giving the host desktop the Steam URI
                    probe = new_method_call(
                        DBusAddress(
                            PORTAL_PATH,
                            bus_name=fields[HeaderFields.destination],
                            interface="org.freedesktop.DBus.Properties",
                        ),
                        "Get",
                        "ss",
                        (OPEN_URI, "version"),
                    )
                    probe.header.flags = (
                        message.header.flags & ~NO_REPLY_EXPECTED
                    )
                    data = probe.serialise(serial=message.header.serial)
            await remote.send(data)

    async def incoming() -> None:
        nonlocal unique_name
        while True:
            data, message = await remote.receive()
            fields = message.header.fields
            destination = fields.get(HeaderFields.destination)
            if isinstance(destination, str) and destination.startswith(":"):
                unique_name = destination
            original = (
                pending.pop(fields.get(HeaderFields.reply_serial), None)
                if message.header.message_type
                in (MessageType.method_return, MessageType.error)
                else None
            )
            if original is None:
                async for chunk in files.incoming(data, message):
                    await local.send(chunk)
                continue
            for path, request_serial in list(pending_paths.items()):
                if request_serial == original.header.serial:
                    pending_paths.pop(path)
            closes = pending_closes.pop(original.header.serial, [])
            sender = fields.get(HeaderFields.sender)
            matching_closes = []
            for close in closes:
                if close.header.fields.get(HeaderFields.destination) in (
                    PORTAL,
                    sender,
                ):
                    matching_closes.append(close)
                else:
                    # A predicted handle alone does not establish which
                    # service a unique-name Close addresses. Resolve the owner
                    # first, then leave other services' calls untouched
                    await remote.send(close.serialise())
            closes = matching_closes
            if message.header.message_type == MessageType.error:
                # The probe shares the original serial, so the real portal's
                # error is also a valid failure reply to the original call
                if not original.header.flags & NO_REPLY_EXPECTED:
                    await local.send(data)
                for close in closes:
                    if not close.header.flags & NO_REPLY_EXPECTED:
                        await send(
                            new_error(
                                close,
                                fields.get(
                                    HeaderFields.error_name,
                                    "org.freedesktop.DBus.Error.Failed",
                                ),
                            ),
                            fields.get(HeaderFields.sender),
                        )
                continue
            try:
                if not unique_name or not sender:
                    raise ValueError("the portal reply has no bus identity")
                path = steam_request_path(original, unique_name)
            except ValueError:
                if not original.header.flags & NO_REPLY_EXPECTED:
                    await send(
                        new_error(
                            original, "org.freedesktop.DBus.Error.InvalidArgs"
                        ),
                        sender,
                    )
                continue
            if path in requests:
                if not original.header.flags & NO_REPLY_EXPECTED:
                    await send(
                        new_error(
                            original, "org.freedesktop.DBus.Error.InvalidArgs"
                        ),
                        sender,
                    )
                continue
            if closes:
                if not original.header.flags & NO_REPLY_EXPECTED:
                    await send(
                        new_method_return(original, "o", (path,)), sender
                    )
                for close in closes:
                    if not close.header.flags & NO_REPLY_EXPECTED:
                        await send(new_method_return(close), sender)
                continue
            requests[path] = (
                sender,
                tasks.create_task(complete(path, original.body[1], sender)),
            )
            if not original.header.flags & NO_REPLY_EXPECTED:
                await send(new_method_return(original, "o", (path,)), sender)

    async def pump(operation, destination: MessageStream) -> None:
        nonlocal client_closed
        try:
            await operation()
        except asyncio.IncompleteReadError as error:
            if error.partial:
                raise ValueError("truncated D-Bus message") from error
            if destination is remote:
                client_closed = True
            else:
                if not client_closed:
                    print(
                        "WARNING: Host session bus disconnected; restart "
                        "Steam if existing clients fail",
                        file=sys.stderr,
                    )
                active = [task for _, task in requests.values()]
                if not client_closed:
                    for task in active:
                        task.cancel()
                # A caller can half-close after its final request. Drain the
                # bounded local FIFO operations before closing its read side
                await asyncio.gather(*active, return_exceptions=True)
            await destination.send_eof()

    # aiotools annotates the variadic __aexit__ arguments as one tuple
    async with TaskScope(  # ty: ignore[invalid-context-manager]
        exception_handler=None
    ) as tasks:
        try:
            await asyncio.gather(
                tasks.create_task(pump(outgoing, remote)),
                tasks.create_task(pump(incoming, local)),
            )
        except ConnectionError:
            pass
        finally:
            tasks.abort()
