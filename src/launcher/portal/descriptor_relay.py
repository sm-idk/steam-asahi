"""Relay portal resources with caller-scoped Cap'n Proto capabilities"""

from __future__ import annotations

import asyncio
import os
import socket
from contextlib import suppress
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Any, Literal

import msgspec
from aiotools import TaskScope, race
from jeepney import (
    HeaderFields as H,
    Message,
    MessageFlag,
    MessageType,
    new_error,
)
from jeepney.bus_messages import message_bus

from .descriptors import (
    IO_TIMEOUT,
    ZERO_TOKEN,
    PipeWireHelper,
    RegistryClient,
    UnixMessage,
    UnixMessageSocket,
    wait_unix_disconnect,
)
from .portal import (
    MessageStream,
    decode_message,
    descriptor_operation,
    relay_portal_messages,
)
from .protocol import MAX_MESSAGE_BYTES, MAX_REQUESTS, PORTAL, SESSION, matches
from .rpc import RPC, capnp, scoped

if TYPE_CHECKING:
    from resources import Namespace

MAX_RESOURCE_METADATA = 64 * 1024


@dataclass
class PendingRemote:
    message: Message
    cancelled: bool = False
    claimed: bool = False
    closed_owners: set[str] = field(default_factory=set)

    def cancelled_for(self, owner: str) -> bool:
        return self.cancelled or owner in self.closed_owners


@dataclass
class Resource:
    token: bytes
    session: str
    owner: str
    helper: PipeWireHelper | None = None
    peer: Any = None
    prepared: bool = False
    revoked: bool = False


class Lease(RPC.Lease.Server):
    def __init__(self, relay: DescriptorRelay, resource: Resource) -> None:
        self.relay, self.resource = relay, resource
        self.owner = relay

    @scoped
    async def ready(self, peer, **_) -> None:
        resource = self.resource
        registry = self.relay.registry
        if registry is None or resource.revoked or resource.prepared:
            raise ValueError("resource is not awaiting preparation")
        resource.prepared = True
        resource.peer = peer
        await registry.wait_ready(resource.token)
        if resource.revoked:
            raise ValueError("resource ended during preparation")

    @scoped
    async def close(self, **_) -> None:
        await self.relay.revoke(self.resource, notify=False)


class MessageQueue:
    """Buffer complete descriptor-free messages within the byte budget"""

    def __init__(self) -> None:
        self.messages: asyncio.Queue[tuple[bytes, Message]] = asyncio.Queue()
        self.pending_bytes = 0

    def feed(self, data: bytes, message: Message) -> None:
        if self.pending_bytes + len(data) > MAX_MESSAGE_BYTES:
            raise ValueError("ordinary portal input queue exceeds its limit")
        self.messages.put_nowait((data, message))
        self.pending_bytes += len(data)

    async def receive(self) -> tuple[bytes, Message]:
        try:
            data, message = await self.messages.get()
        except asyncio.QueueShutDown:
            raise asyncio.IncompleteReadError(b"", 16) from None
        self.pending_bytes -= len(data)
        return data, message

    def close(self) -> None:
        self.messages.shutdown()


def resource_error(
    message: Message, error: Exception, *, reply: bool = False
) -> bytes:
    result = new_error(
        message, "org.freedesktop.DBus.Error.NotSupported", "s", (str(error),)
    )
    if reply:
        result.header.fields[H.reply_serial] = message.header.fields[
            H.reply_serial
        ]
        for key in (H.sender, H.destination):
            if key in message.header.fields:
                result.header.fields[key] = message.header.fields[key]
    return result.serialise(serial=message.header.serial or 1)


class DescriptorRelay(RPC.Peer.Server):
    """One caller owns its bus socket, resource capabilities, and registry"""

    def __init__(
        self,
        local: UnixMessageSocket,
        side: Literal["host", "guest"],
        *,
        namespace: Namespace | None = None,
        registry: RegistryClient | None = None,
        helper: Path | None = None,
    ) -> None:
        self.local, self.side = local, side
        self.namespace, self.registry, self.helper = namespace, registry, helper
        self.pending: dict[int, PendingRemote] = {}
        self.leases: dict[bytes, Resource] = {}
        self.finished = asyncio.Event()
        self.connected = asyncio.Event()
        self.failure: BaseException | None = None
        self.ordinary_local = MessageQueue()
        self.ordinary_host = MessageQueue()
        self.outgoing_drained = asyncio.Event()
        self.hello_serial: int | None = None
        self.owner_setup: tuple[int, bytes] | None = None
        self.owner_timer: asyncio.Task | None = None
        self.owner_watch = False
        self.incoming = asyncio.Lock()
        self.message_eof = False
        self.peer = None
        self.jobs = 0
        self.credit = asyncio.Condition()
        self.send_slots = asyncio.Semaphore(32)
        self.pending_bytes = 0
        self.owner = self
        self.operations = self.operation_bytes = 0
        self.byte_limit = MAX_MESSAGE_BYTES + MAX_RESOURCE_METADATA

    def start_job(self, operation) -> asyncio.Task:
        if self.jobs >= MAX_REQUESTS * 3:
            operation.close()
            raise ValueError("too many pending portal resource operations")
        self.jobs += 1

        def finished(_task):
            self.jobs -= 1

        task = self.tasks.create_task(operation)
        task.add_done_callback(finished)
        return task

    @scoped
    async def connect(self, peer, **_) -> None:
        if self.side != "host" or self.connected.is_set():
            raise ValueError("resource peer is already connected")
        self.peer = peer
        self.connected.set()

    async def send_message(self, data: bytes) -> None:
        decode_message(data)
        await self.send_slots.acquire()
        async with self.credit:
            await self.credit.wait_for(
                lambda: self.pending_bytes + len(data) <= MAX_MESSAGE_BYTES
            )
            self.pending_bytes += len(data)
            response = self.peer.message(data=data)
            self.start_job(self.sent(response, len(data)))

    async def sent(self, response, size: int) -> None:
        try:
            await response
        finally:
            async with self.credit:
                self.pending_bytes -= size
                self.credit.notify_all()
            self.send_slots.release()

    async def revoke(self, resource: Resource, *, notify: bool) -> None:
        if resource.revoked:
            return
        resource.revoked = True
        self.leases.pop(resource.token, None)
        # Release reciprocal capabilities even when only one peer closes
        peer, resource.peer = resource.peer, None
        if self.registry is not None:
            await self.registry.revoke(resource.token)
        if resource.helper is not None:
            await resource.helper.close()
        if notify and peer is not None:
            await peer.close()

    async def observe(self, message: Message) -> None:
        fields = message.header.fields
        if (
            self.side == "host"
            and not self.owner_watch
            and self.owner_setup is None
            and matches(
                message,
                type="method_call",
                destination="org.freedesktop.DBus",
                interface="org.freedesktop.DBus",
                member="Hello",
            )
        ):
            self.hello_serial = message.header.serial
        if descriptor_operation(message) == "pipewire":
            if len(self.pending) >= MAX_REQUESTS:
                raise ValueError("too many pending PipeWire portal calls")
            if message.header.flags & int(MessageFlag.no_reply_expected):
                raise ValueError("PipeWire remote requires a method reply")
            if message.header.serial in self.pending:
                raise ValueError("PipeWire portal serial is already pending")
            self.pending[message.header.serial] = PendingRemote(message)
        session = fields.get(H.path)
        destination = fields.get(H.destination)
        sender = fields.get(H.sender)
        closing = (
            matches(
                message, type="method_call", interface=SESSION, member="Close"
            )
            and not message.body
        )
        closed = matches(
            message, type="signal", interface=SESSION, member="Closed"
        )
        owners_lost: set[str] = set()
        portal_lost = False
        if (
            matches(
                message,
                type="signal",
                sender="org.freedesktop.DBus",
                interface="org.freedesktop.DBus",
                member="NameOwnerChanged",
                signature="sss",
            )
            and (message.body[0] == PORTAL or message.body[0].startswith(":"))
            and message.body[1]
            and message.body[1] != message.body[2]
        ):
            owners_lost.add(message.body[1])
            portal_lost = message.body[0] == PORTAL
        for pending in self.pending.values():
            if pending.cancelled:
                continue
            original = pending.message
            owner = original.header.fields.get(H.destination)
            if owner in owners_lost or (portal_lost and owner == PORTAL):
                pending.cancelled = True
            if original.body[0] == session:
                if closing:
                    if destination in (PORTAL, owner):
                        pending.cancelled = True
                    elif owner == PORTAL and str(destination).startswith(":"):
                        pending.closed_owners.add(destination)
                elif closed and str(sender).startswith(":"):
                    # A well-known destination's owner is established by its
                    # reply, so bind early Closed signals to that unique name
                    pending.closed_owners.add(sender)
                if len(pending.closed_owners) > MAX_REQUESTS:
                    pending.cancelled = True
        for resource in list(self.leases.values()):
            if resource.owner in owners_lost or (
                resource.session == session
                and (
                    (closing and destination in (PORTAL, resource.owner))
                    or (closed and sender == resource.owner)
                )
            ):
                await self.revoke(resource, notify=True)

    async def local_message(self, packet: UnixMessage) -> None:
        message = packet.message
        fields = message.header.fields
        if self.side == "host" and await self.watch_handshake(packet):
            return
        if packet.descriptors and self.side == "guest":
            try:
                await self.export_file(packet)
            except (ImportError, OSError, ValueError) as error:
                if not message.header.flags & int(
                    MessageFlag.no_reply_expected
                ):
                    await self.local.send(resource_error(message, error))
            return
        if packet.descriptors:
            await self.export_pipewire(packet)
            return
        try:
            await self.observe(message)
        except ValueError as error:
            if self.side != "guest" or descriptor_operation(message) is None:
                raise
            if not message.header.flags & int(MessageFlag.no_reply_expected):
                await self.local.send(resource_error(message, error))
            return
        if self.side == "host" and message.header.message_type in (
            MessageType.method_return,
            MessageType.error,
        ):
            original = self.pending.pop(fields.get(H.reply_serial), None)
            if (
                original is not None
                and message.header.message_type != MessageType.error
            ):
                await self.send_message(
                    resource_error(
                        message,
                        ValueError("portal returned no PipeWire descriptor"),
                        reply=True,
                    ),
                )
                return
        if self.side == "guest":
            self.ordinary_local.feed(packet.data, message)
        else:
            await self.send_message(packet.data)

    async def watch_handshake(self, packet: UnixMessage) -> bool:
        message = packet.message
        fields = message.header.fields
        if (
            packet.descriptors
            or message.header.message_type
            not in (
                MessageType.method_return,
                MessageType.error,
            )
            or fields.get(H.sender) != "org.freedesktop.DBus"
        ):
            return False
        reply_serial = fields.get(H.reply_serial)
        if self.owner_setup is not None and reply_serial == self.owner_setup[0]:
            _, hello = self.owner_setup
            self.owner_setup = None
            if self.owner_timer is not None:
                self.owner_timer.cancel()
                self.owner_timer = None
            self.owner_watch = (
                message.header.message_type == MessageType.method_return
                and not message.body
            )
            await self.send_message(hello)
            return True
        if reply_serial != self.hello_serial or self.hello_serial is None:
            return False
        self.hello_serial = None
        if (
            message.header.message_type != MessageType.method_return
            or fields.get(H.signature) != "s"
            or not message.body[0].startswith(":")
        ):
            return False
        # Complete an internal owner-loss match before returning Hello. Reuse
        # its already-replied serial while the caller still awaits Hello, so
        # no independent internal serial can collide with a caller request
        self.owner_setup = (reply_serial, packet.data)
        match = message_bus.AddMatch(
            "type='signal',sender='org.freedesktop.DBus',"
            "interface='org.freedesktop.DBus',member='NameOwnerChanged'"
        )
        await self.local.send(match.serialise(serial=reply_serial))
        self.owner_timer = self.start_job(self.owner_setup_deadline())
        return True

    async def owner_setup_deadline(self) -> None:
        await asyncio.sleep(IO_TIMEOUT)
        if self.owner_setup is not None:
            raise TimeoutError("portal owner-loss subscription did not finish")

    async def export_file(self, packet: UnixMessage) -> None:
        if (
            self.namespace is None
            or descriptor_operation(packet.message) != "shared-file"
            or len(packet.descriptors) != 1
            or packet.message.body[1] != packet.descriptors[0]
        ):
            raise ValueError("this guest descriptor operation is unavailable")
        manifest = self.namespace.descriptor_manifest(packet.descriptors[0])
        if packet.message.body[2].get("writable") == ("b", True) and manifest[
            "access"
        ] not in ("write", "read-write"):
            raise ValueError(
                "the supplied descriptor does not grant write access"
            )
        descriptor = os.dup(packet.descriptors[0])
        try:
            response = self.peer.file(
                data=packet.data, manifest=msgspec.json.encode(manifest)
            )
            task = self.start_job(self.file_sent(response, packet.message))
            task.add_done_callback(lambda _: os.close(descriptor))
        except BaseException:
            os.close(descriptor)
            raise

    async def file_sent(self, response, message: Message) -> None:
        try:
            async with asyncio.timeout(IO_TIMEOUT):
                await response
        except (capnp.KjException, TimeoutError) as error:
            if not message.header.flags & int(MessageFlag.no_reply_expected):
                await self.local.send(resource_error(message, error))

    async def export_pipewire(self, packet: UnixMessage) -> None:
        message = packet.message
        serial = message.header.fields.get(H.reply_serial)
        pending = self.pending.get(serial)
        original = pending.message if pending is not None else None
        resource = None
        try:
            if (
                self.registry is None
                or not self.owner_watch
                or original is None
                or pending is None
                or pending.cancelled
                or message.header.message_type != MessageType.method_return
                or message.header.fields.get(H.signature) != "h"
                or len(packet.descriptors) != 1
                or message.body[0] != packet.descriptors[0]
                or len(self.leases) >= MAX_REQUESTS
            ):
                raise ValueError(
                    "this host descriptor operation is unavailable"
                )
            sender = message.header.fields.get(H.sender, "")
            if not sender.startswith(":") or original.header.fields.get(
                H.destination
            ) not in (PORTAL, sender):
                raise ValueError("PipeWire reply has another portal owner")
            if pending.cancelled_for(sender):
                raise ValueError("portal session ended before its reply")
            token = await self.registry.register(packet.descriptors[0])
            resource = Resource(token, original.body[0], sender)
            self.leases[token] = resource
            if pending.cancelled_for(sender):
                raise ValueError("portal session ended during registration")
            response = self.peer.pipeWire(
                data=packet.data,
                session=resource.session,
                owner=sender,
                token=token,
                lease=Lease(self, resource),
            )
            self.start_job(self.pipewire_sent(response, resource))
        except (OSError, ValueError) as error:
            if resource is not None:
                await self.revoke(resource, notify=False)
            if message.header.message_type != MessageType.method_return:
                raise ValueError(
                    "unsupported descriptor-bearing host message"
                ) from error
            await self.send_message(resource_error(message, error, reply=True))
        finally:
            if self.pending.get(serial) is pending:
                self.pending.pop(serial, None)

    async def pipewire_sent(self, response, resource: Resource) -> None:
        try:
            async with asyncio.timeout(IO_TIMEOUT):
                result = await response
            if not result.accepted:
                await self.revoke(resource, notify=False)
        except BaseException:
            await self.revoke(resource, notify=False)
            raise

    async def watch_helper(self, resource: Resource) -> None:
        assert resource.helper is not None
        await resource.helper.process.wait()
        await self.revoke(resource, notify=True)

    @scoped
    async def pipeWire(self, data, session, owner, token, lease, **_):
        message = decode_message(data, [0])
        serial = message.header.fields.get(H.reply_serial)
        pending = self.pending.get(serial)
        original = pending.message if pending is not None else None
        claimed = pending is not None and not pending.claimed
        if pending is not None:
            if claimed:
                pending.claimed = True
            else:
                pending.cancelled = True
        resource = None
        try:
            if (
                self.message_eof
                or self.side != "guest"
                or self.helper is None
                or original is None
                or pending is None
                or not claimed
                or pending.cancelled
                or message.header.message_type != MessageType.method_return
                or message.header.fields.get(H.signature) != "h"
                or message.body != (0,)
                or session != original.body[0]
                or not session.startswith("/")
                or not owner.startswith(":")
                or owner != message.header.fields.get(H.sender)
                or original.header.fields.get(H.destination)
                not in (PORTAL, owner)
                or len(token) != 16
                or token == ZERO_TOKEN
                or token in self.leases
                or len(self.leases) >= MAX_REQUESTS
            ):
                raise ValueError(
                    "PipeWire resource does not match its portal call"
                )
            if pending.cancelled_for(owner):
                raise ValueError("portal session ended before its reply")
            helper = await PipeWireHelper.start(self.helper, token)
            resource = Resource(token, session, owner, helper, lease)
            self.leases[token] = resource
            self.start_job(self.watch_helper(resource))
            if pending.cancelled_for(owner):
                raise ValueError("portal session ended during helper setup")
            async with asyncio.timeout(IO_TIMEOUT):
                await lease.ready(peer=Lease(self, resource))
            if (
                pending.cancelled_for(owner)
                or resource.revoked
                or helper.process.returncode is not None
            ):
                raise ConnectionError(
                    "registered PipeWire connection ended during setup"
                )
            await self.local.send(data, [helper.connection.fileno()])
            return True
        except (
            OSError,
            ValueError,
            TimeoutError,
            asyncio.IncompleteReadError,
            capnp.KjException,
        ) as error:
            if resource is not None:
                await self.revoke(resource, notify=True)
            else:
                await lease.close()
            await self.local.send(resource_error(message, error, reply=True))
            return False
        finally:
            if claimed and self.pending.get(serial) is pending:
                self.pending.pop(serial, None)

    @scoped
    async def file(self, data, manifest, **_) -> None:
        from resources import reopen_descriptor

        async with self.incoming:
            message = decode_message(data, [0])
            if (
                self.message_eof
                or self.side != "host"
                or descriptor_operation(message) != "shared-file"
                or message.body[1] != 0
            ):
                raise ValueError("this shared file operation is unavailable")
            if len(manifest) > MAX_RESOURCE_METADATA:
                raise ValueError("shared file metadata exceeds its limit")
            manifest = msgspec.json.decode(manifest)
            descriptor = reopen_descriptor(manifest)
            try:
                if message.body[2].get("writable") == ("b", True) and manifest[
                    "access"
                ] not in ("write", "read-write"):
                    raise ValueError(
                        "the supplied descriptor does not grant write access"
                    )
                await self.local.send(data, [descriptor])
            finally:
                os.close(descriptor)

    @scoped
    async def message(self, data, **_) -> None:
        async with self.incoming:
            if self.message_eof:
                raise ValueError("portal message follows EOF")
            message = decode_message(data)
            await self.observe(message)
            if self.side == "guest":
                if message.header.message_type in (
                    MessageType.method_return,
                    MessageType.error,
                ):
                    self.pending.pop(
                        message.header.fields.get(H.reply_serial), None
                    )
                self.ordinary_host.feed(data, message)
            else:
                await self.local.send(data)

    @scoped
    async def eof(self, **_) -> None:
        async with self.incoming:
            if self.message_eof:
                raise ValueError("repeated portal message EOF")
            self.message_eof = True
            if self.side == "guest":
                for pending in self.pending.values():
                    pending.cancelled = True
                self.ordinary_host.close()

    async def run(self, channel: socket.socket) -> None:
        def failed(context) -> None:
            self.failure = context["exception"]
            self.finished.set()

        async def half_close_local() -> None:
            with suppress(OSError):
                self.local.connection.shutdown(socket.SHUT_WR)
            self.finished.set()

        async def caller_disconnect() -> None:
            await wait_unix_disconnect(self.local.connection)
            self.finished.set()

        async def disconnected() -> None:
            await self.rpc.on_disconnect()
            if self.side == "guest":
                for pending in self.pending.values():
                    pending.cancelled = True
                self.ordinary_host.close()
            else:
                self.finished.set()

        async def local_messages() -> None:
            try:
                while True:
                    with await self.local.receive() as packet:
                        await self.local_message(packet)
            except asyncio.IncompleteReadError as error:
                if error.partial or self.local.connection.fileno() < 0:
                    raise ValueError("truncated local D-Bus message") from error
                if self.side == "guest":
                    self.ordinary_local.close()
                    await self.outgoing_drained.wait()
                async with self.credit:
                    await self.credit.wait_for(lambda: self.pending_bytes == 0)
                await self.peer.eof()
                if self.side == "host":
                    self.finished.set()

        async def ordinary_message(data: bytes) -> None:
            if self.outgoing_drained.is_set():
                raise ValueError("ordinary portal output is closed")
            await self.send_message(data)

        async def outgoing_eof() -> None:
            self.outgoing_drained.set()

        stream = await capnp.AsyncIoStream.create_connection(sock=channel)
        try:
            async with (
                TaskScope(exception_handler=failed) as self.tasks,
                TaskScope(exception_handler=None) as self.calls,
            ):
                self.rpc = None
                try:
                    if self.side == "host":
                        self.rpc = capnp.TwoPartyServer(
                            stream,
                            bootstrap=self,
                            traversal_limit_in_words=(
                                MAX_MESSAGE_BYTES + MAX_RESOURCE_METADATA
                            )
                            // 8,
                        )
                        self.start_job(disconnected())
                        async with asyncio.timeout(IO_TIMEOUT):
                            await race(
                                [self.connected.wait(), self.finished.wait()]
                            )
                        if not self.connected.is_set():
                            raise ConnectionError(
                                "resource peer disconnected during setup"
                            )
                    else:
                        self.rpc = capnp.TwoPartyClient(
                            stream,
                            traversal_limit_in_words=(
                                MAX_MESSAGE_BYTES + MAX_RESOURCE_METADATA
                            )
                            // 8,
                        )
                        self.peer = self.rpc.bootstrap().cast_as(RPC.Peer)
                        async with asyncio.timeout(IO_TIMEOUT):
                            await self.peer.connect(peer=self)
                        self.start_job(disconnected())
                    self.start_job(local_messages())
                    if self.side == "guest":
                        self.start_job(caller_disconnect())
                        self.start_job(
                            relay_portal_messages(
                                MessageStream(
                                    self.ordinary_local.receive,
                                    self.local.send,
                                    half_close_local,
                                ),
                                MessageStream(
                                    self.ordinary_host.receive,
                                    ordinary_message,
                                    outgoing_eof,
                                ),
                                namespace=self.namespace,
                            )
                        )
                    await self.finished.wait()
                    if self.failure is not None:
                        raise self.failure
                finally:
                    self.tasks.abort()
                    self.calls.abort()
                    if self.registry is not None:
                        self.registry.close()
                    if self.rpc is not None:
                        self.rpc.close()
                    stream.close()
        finally:
            stream.close()
            self.local.close()
            for resource in list(self.leases.values()):
                if resource.helper is not None:
                    await resource.helper.close()
            self.leases.clear()
