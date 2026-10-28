"""Experimental descriptor transport for one caller's portal connection

The default relay declines Unix FD passing; opt-in roles own raw Unix
endpoints so an asyncio byte transport cannot discard ancillary data
"""

from __future__ import annotations

import array
import asyncio
import errno
import os
import select
import socket
import struct
from collections.abc import Sequence
from contextlib import suppress
from dataclasses import dataclass, field
from pathlib import Path

from anyio import wait_readable
from jeepney import Message
from jeepney.low_level import calc_msg_size

from ..portal import decode_message
from ..protocol import MAX_MESSAGE_BYTES

MAX_DESCRIPTORS = 16
MAX_KERNEL_DESCRIPTORS = 253
IO_TIMEOUT = 10
REGISTRY_FRAME = struct.Struct("<4sIi16s")
ZERO_TOKEN = bytes(16)
PING, REGISTER, REVOKE, STATUS = 0, 1, 2, 3
REPLY = 1 << 31


def close_descriptors(descriptors: list[int]) -> None:
    while descriptors:
        os.close(descriptors.pop())


async def socket_ready(
    connection: socket.socket, *, write: bool = False
) -> None:
    loop = asyncio.get_running_loop()
    ready = loop.create_future()
    descriptor = connection.fileno()
    if descriptor < 0:
        raise ConnectionError("the descriptor transport is closed")
    add = loop.add_writer if write else loop.add_reader
    remove = loop.remove_writer if write else loop.remove_reader

    def wake() -> None:
        if not ready.done():
            ready.set_result(None)

    add(descriptor, wake)
    try:
        await ready
    finally:
        # A closed socket's descriptor may already belong to another connection
        if connection.fileno() == descriptor:
            remove(descriptor)


def _close_unix_socket(connection: socket.socket) -> None:
    """Detach loop callbacks before releasing a reusable descriptor number"""
    descriptor = connection.fileno()
    if descriptor < 0:
        return
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        pass
    else:
        loop.remove_reader(descriptor)
        loop.remove_writer(descriptor)
    with suppress(OSError):
        connection.shutdown(socket.SHUT_RDWR)
    connection.close()


async def wait_unix_disconnect(connection: socket.socket) -> None:
    """Wait for full peer loss without treating request-side EOF as disconnect

    A zero epoll mask reports HUP/ERR without requesting read or RDHUP events,
    so SHUT_WR does not repeatedly wake an already exhausted socket reader
    """
    descriptor = connection.fileno()
    if descriptor < 0:
        raise ConnectionError("the caller socket is closed")
    # Readiness cleanup completes before this scope releases the epoll FD
    with select.epoll() as events:
        events.register(descriptor, 0)
        while True:
            await wait_readable(events)
            if any(
                mask & (select.EPOLLHUP | select.EPOLLERR)
                for _, mask in events.poll(0)
            ):
                return


async def receive_ancillary(
    connection: socket.socket, size: int
) -> tuple[bytes, list[int]]:
    width = array.array("i").itemsize
    while True:
        try:
            data, controls, flags, _ = connection.recvmsg(
                size,
                socket.CMSG_SPACE(MAX_KERNEL_DESCRIPTORS * width),
                socket.MSG_CMSG_CLOEXEC,
            )
            break
        except BlockingIOError, InterruptedError:
            await socket_ready(connection)
    descriptors: list[int] = []
    invalid = False
    try:
        # Collect installed FDs before rejecting any malformed/truncated record
        for level, kind, payload in controls:
            if (level, kind) != (socket.SOL_SOCKET, socket.SCM_RIGHTS):
                invalid = True
                continue
            values = array.array("i")
            complete = len(payload) - len(payload) % width
            values.frombytes(payload[:complete])
            descriptors.extend(values)
            invalid |= complete != len(payload)
        if invalid or flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC):
            raise ValueError("invalid or truncated descriptor ancillary data")
        return data, descriptors
    except BaseException:
        close_descriptors(descriptors)
        raise


@dataclass
class UnixMessage:
    data: bytes
    message: Message
    descriptors: list[int] = field(default_factory=list, repr=False)

    def close(self) -> None:
        close_descriptors(self.descriptors)

    def __enter__(self) -> UnixMessage:
        return self

    def __exit__(self, *_exc) -> None:
        self.close()


class UnixMessageSocket:
    """Own a raw Unix stream, preserving message boundaries and FD ownership"""

    def __init__(self, connection: socket.socket) -> None:
        if connection.family != socket.AF_UNIX or not hasattr(
            connection, "recvmsg"
        ):
            raise ValueError("descriptor capture requires a raw Unix socket")
        if connection.getsockopt(socket.SOL_SOCKET, socket.SO_TYPE) != (
            socket.SOCK_STREAM
        ):
            raise ValueError("D-Bus requires a Unix stream socket")
        connection.setblocking(False)
        self.connection = connection
        self.receiving = asyncio.Lock()
        self.sending = asyncio.Lock()

    def close(self) -> None:
        _close_unix_socket(self.connection)

    async def _read_exactly(self, size: int, descriptors: list[int]) -> bytes:
        result = bytearray()
        while len(result) < size:
            data, received = await receive_ancillary(
                self.connection, min(size - len(result), 65536)
            )
            descriptors.extend(received)
            if len(descriptors) > MAX_DESCRIPTORS:
                raise ValueError("too many D-Bus descriptors")
            if not data:
                raise asyncio.IncompleteReadError(bytes(result), size)
            result.extend(data)
        return bytes(result)

    async def receive(self) -> UnixMessage:
        descriptors: list[int] = []
        started = False
        async with self.receiving:
            try:
                first = await self._read_exactly(1, descriptors)
                started = True
                async with asyncio.timeout(IO_TIMEOUT):
                    header = first + await self._read_exactly(15, descriptors)
                    if header[:1] not in (b"l", b"B") or header[3] != 1:
                        raise ValueError("invalid D-Bus message header")
                    size = calc_msg_size(header)
                    if not 16 <= size <= MAX_MESSAGE_BYTES:
                        raise ValueError("D-Bus message exceeds the size limit")
                    data = header + await self._read_exactly(
                        size - 16, descriptors
                    )
                    return UnixMessage(
                        data, decode_message(data, descriptors), descriptors
                    )
            except asyncio.IncompleteReadError:
                close_descriptors(descriptors)
                if started:
                    self.close()
                raise
            except BaseException:
                close_descriptors(descriptors)
                # A partially consumed message cannot be resumed by another
                # receiver or safely followed by another D-Bus message
                self.close()
                raise

    async def send(self, data: bytes, descriptors: Sequence[int] = ()) -> None:
        if len(descriptors) > MAX_DESCRIPTORS:
            raise ValueError("too many D-Bus descriptors")
        decode_message(data, descriptors)
        async with self.sending:
            try:
                async with asyncio.timeout(IO_TIMEOUT):
                    sent = 0
                    if descriptors:
                        controls = [
                            (
                                socket.SOL_SOCKET,
                                socket.SCM_RIGHTS,
                                array.array("i", descriptors),
                            )
                        ]
                        while True:
                            try:
                                sent = self.connection.sendmsg(
                                    [data], controls, socket.MSG_NOSIGNAL
                                )
                                break
                            except BlockingIOError, InterruptedError:
                                await socket_ready(self.connection, write=True)
                        if sent == 0:
                            raise ConnectionError(
                                "D-Bus write made no progress"
                            )
                    # SCM_RIGHTS accompanies only the first successful write
                    # asyncio owns partial writes of the remaining plain bytes
                    await asyncio.get_running_loop().sock_sendall(
                        self.connection,
                        memoryview(data)[sent:] if sent else data,
                    )
            except BaseException:
                self.close()
                raise


class RegistryClient:
    """One persistent control connection owns every registration for a caller"""

    def __init__(self, connection: socket.socket) -> None:
        if (
            connection.family != socket.AF_UNIX
            or connection.getsockopt(socket.SOL_SOCKET, socket.SO_TYPE)
            != socket.SOCK_SEQPACKET
        ):
            raise ValueError("registry control requires Unix SOCK_SEQPACKET")
        connection.setblocking(False)
        self.connection = connection
        self.requests = asyncio.Lock()
        self.tokens: set[bytes] = set()

    @classmethod
    async def connect(cls, path: Path) -> RegistryClient:
        if not path.is_absolute():
            raise ValueError("registry path must be absolute")
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        connection.setblocking(False)
        try:
            async with asyncio.timeout(IO_TIMEOUT):
                await asyncio.get_running_loop().sock_connect(
                    connection, str(path)
                )
            credentials = connection.getsockopt(
                socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")
            )
            if struct.unpack("3i", credentials)[1] != os.geteuid():
                raise PermissionError("registry control peer has another UID")
            return cls(connection)
        except BaseException:
            connection.close()
            raise

    def close(self) -> None:
        _close_unix_socket(self.connection)
        self.tokens.clear()

    async def request(
        self,
        operation: int,
        token: bytes = ZERO_TOKEN,
        descriptor: int | None = None,
    ) -> bytes:
        if len(token) != 16 or operation not in (
            PING,
            REGISTER,
            REVOKE,
            STATUS,
        ):
            raise ValueError("invalid registry operation")
        if operation in (PING, REGISTER) and token != ZERO_TOKEN:
            raise ValueError("registry operation requires an empty token")
        if (operation == REGISTER) != (descriptor is not None):
            raise ValueError(
                "registry operation has the wrong descriptor count"
            )
        frame = REGISTRY_FRAME.pack(b"KPW1", operation, 0, token)
        async with self.requests:
            try:
                async with asyncio.timeout(IO_TIMEOUT):
                    while True:
                        try:
                            controls = (
                                []
                                if descriptor is None
                                else [
                                    (
                                        socket.SOL_SOCKET,
                                        socket.SCM_RIGHTS,
                                        array.array("i", [descriptor]),
                                    )
                                ]
                            )
                            count = self.connection.sendmsg(
                                [frame], controls, socket.MSG_NOSIGNAL
                            )
                            if count != len(frame):
                                raise ValueError("truncated registry request")
                            break
                        except BlockingIOError, InterruptedError:
                            await socket_ready(self.connection, write=True)
                    reply, descriptors = await receive_ancillary(
                        self.connection, REGISTRY_FRAME.size + 1
                    )
                    try:
                        if descriptors or len(reply) != REGISTRY_FRAME.size:
                            raise ValueError("invalid registry response length")
                        magic, response, status, result = REGISTRY_FRAME.unpack(
                            reply
                        )
                        if (
                            magic != b"KPW1"
                            or response != operation | REPLY
                            or status > 0
                        ):
                            raise ValueError("invalid registry response")
                        if operation != REGISTER and result != token:
                            raise ValueError(
                                "registry response has another token"
                            )
                        if status < 0:
                            raise OSError(
                                -status, "portal registry operation failed"
                            )
                        if operation == REGISTER and result == ZERO_TOKEN:
                            raise ValueError("registry returned an empty token")
                        return result
                    finally:
                        close_descriptors(descriptors)
            except OSError as error:
                if error.errno not in (errno.EAGAIN, errno.ENOENT):
                    self.close()
                raise
            except BaseException:
                self.close()
                raise

    async def ping(self) -> None:
        await self.request(PING)

    async def register(self, descriptor: int) -> bytes:
        token = await self.request(REGISTER, descriptor=descriptor)
        if token in self.tokens:
            self.close()
            raise ValueError("registry reused a live token")
        self.tokens.add(token)
        return token

    async def revoke(self, token: bytes) -> None:
        if token not in self.tokens:
            return
        try:
            await self.request(REVOKE, token)
        except OSError as error:
            if error.errno != errno.ENOENT:
                raise
        finally:
            self.tokens.discard(token)

    async def wait_ready(self, token: bytes) -> None:
        if token not in self.tokens:
            raise ValueError("registration is not owned by this caller")
        async with asyncio.timeout(IO_TIMEOUT):
            while True:
                try:
                    await self.request(STATUS, token)
                    return
                except OSError as error:
                    if error.errno != errno.EAGAIN:
                        raise
                await asyncio.sleep(0.025)


class PipeWireHelper:
    """Hold the reconstructed local stream until its portal session ends"""

    def __init__(
        self, process: asyncio.subprocess.Process, connection: socket.socket
    ) -> None:
        self.process, self.connection = process, connection

    @classmethod
    async def start(cls, executable: Path, token: bytes) -> PipeWireHelper:
        if (
            not executable.is_absolute()
            or len(token) != 16
            or token == ZERO_TOKEN
        ):
            raise ValueError("invalid registered PipeWire helper request")
        application, bridge = socket.socketpair()
        process = None
        try:
            process = await asyncio.create_subprocess_exec(
                str(executable),
                str(bridge.fileno()),
                pass_fds=(bridge.fileno(),),
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
            bridge.close()
            async with asyncio.timeout(IO_TIMEOUT):
                assert process.stdin is not None and process.stdout is not None
                process.stdin.write(token)
                await process.stdin.drain()
                process.stdin.close()
                if await process.stdout.readexactly(6) != b"READY\n":
                    raise ValueError("registered PipeWire helper is not ready")
                if process.returncode is not None:
                    raise ConnectionError("registered PipeWire helper exited")
            return cls(process, application)
        except BaseException:
            bridge.close()
            application.close()
            if process is not None:
                await cls(process, application).close()
            raise

    async def close(self) -> None:
        with suppress(OSError):
            self.connection.shutdown(socket.SHUT_RDWR)
        self.connection.close()
        if self.process.returncode is None:
            with suppress(ProcessLookupError):
                self.process.terminate()
            try:
                async with asyncio.timeout(2):
                    await self.process.wait()
            except TimeoutError:
                with suppress(ProcessLookupError):
                    self.process.kill()
                await self.process.wait()
        if self.process.stdin is not None:
            self.process.stdin.close()
