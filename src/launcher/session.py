"""Authenticate raw session sockets before selecting byte or typed relays"""

from __future__ import annotations

import asyncio
import os
import re
import socket
import struct
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import Literal
from urllib.parse import quote_from_bytes, unquote_to_bytes

lazy from anyio.abc import UNIXSocketStream

lazy from environment import runtime_directory

lazy from transport import (
    BUS_PORT,
    channel_path,
    close_streams,
    relay_streams,
    start_listener,
)
lazy from wayland import initialize_guest_wayland

BUS_SOCKET_NAME = "steam-asahi-bus"
BUS_AUTH_LIMIT = 16384
PEER_CREDENTIALS = struct.Struct("3i")
RESOURCE_AUTH_PREFACE = b"KDB2AUTH"
RESOURCE_AUTH_ENABLED = b"KDB2FD\r\n"
RESOURCE_AUTH_DISABLED = b"KDB2NO\r\n"


def unix_bus_addresses(address: str) -> list[bytes]:
    candidates = []
    errors = []
    for entry in address.split(";"):
        transport, separator, parameters = entry.partition(":")
        if not separator or transport != "unix":
            continue
        try:
            options = dict(
                parameter.split("=", 1)
                for parameter in parameters.split(",")
                if "=" in parameter
            )
            if re.search(r"%(?![0-9a-fA-F]{2})", parameters):
                raise ValueError("invalid escape in session bus address")
            if "path" in options:
                path = unquote_to_bytes(options["path"])
                if not path.startswith(b"/") or b"\0" in path:
                    raise ValueError("session bus path must be absolute")
                candidates.append(path)
            elif "abstract" in options:
                name = unquote_to_bytes(options["abstract"])
                if not name or b"\0" in name:
                    raise ValueError("invalid abstract session bus address")
                candidates.append(b"\0" + name)
            else:
                raise ValueError(
                    "Unix session bus entry has no connectable endpoint"
                )
        except ValueError as error:
            errors.append(str(error))
    if not candidates:
        raise ValueError(
            "; ".join(errors) or "the session bus must use a Unix socket"
        )
    return candidates


async def connect_session_bus(address: str) -> socket.socket:
    errors = []
    for candidate in unix_bus_addresses(address):
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.setblocking(False)
        try:
            async with asyncio.timeout(5):
                await asyncio.get_running_loop().sock_connect(
                    connection, os.fsdecode(candidate)
                )
        except (OSError, TimeoutError) as error:
            connection.close()
            errors.append(f"{os.fsdecode(candidate)!r}: {error}")
        except BaseException:
            connection.close()
            raise
        else:
            return connection
    raise OSError(
        "no reachable Unix session bus endpoint: " + "; ".join(errors)
    )


async def relay_descriptor_bus(
    connection: socket.socket,
    channel: socket.socket,
    side: Literal["host", "guest"],
    *,
    registry=None,
    helper: Path | None = None,
) -> None:
    from portal.descriptor_relay import DescriptorRelay
    from portal.descriptors import UnixMessageSocket
    from resources import Namespace

    namespace = None
    if side == "guest":
        try:
            namespace = Namespace.from_socket(connection)
        except (OSError, ValueError) as error:
            print(
                f"WARNING: Caller file resources unavailable: {error}",
                file=sys.stderr,
            )
    try:
        local, remote = (
            RawBusAuthentication(connection),
            RawBusAuthentication(channel),
        )
        if side == "host":
            local, remote = remote, local
        await relay_bus_auth(local, remote)
        await DescriptorRelay(
            UnixMessageSocket(connection),
            side,
            namespace=namespace,
            registry=registry,
            helper=helper,
        ).run(channel)
    finally:
        if namespace is not None:
            namespace.close()


class RawBusAuthentication:
    """Read auth without consuming the first binary byte or its SCM_RIGHTS"""

    def __init__(self, connection: socket.socket) -> None:
        if (
            connection.family not in (socket.AF_UNIX, socket.AF_VSOCK)
            or connection.getsockopt(socket.SOL_SOCKET, socket.SO_TYPE)
            != socket.SOCK_STREAM
        ):
            raise ValueError(
                "raw D-Bus authentication requires a local or VM stream"
            )
        connection.setblocking(False)
        self.connection = connection

    async def byte(self) -> bytes:
        from portal.descriptors import close_descriptors, receive_ancillary

        if self.connection.family == socket.AF_VSOCK:
            data = await asyncio.get_running_loop().sock_recv(
                self.connection, 1
            )
            if not data:
                raise asyncio.IncompleteReadError(b"", 1)
            return data
        data, descriptors = await receive_ancillary(self.connection, 1)
        try:
            if descriptors:
                raise ValueError("descriptors are invalid during bus auth")
            if not data:
                raise asyncio.IncompleteReadError(b"", 1)
            return data
        finally:
            close_descriptors(descriptors)

    async def line(self) -> bytes:
        result = bytearray()
        while len(result) < BUS_AUTH_LIMIT:
            result.extend(await self.byte())
            if result.endswith(b"\r\n"):
                return bytes(result)
        raise ValueError("session bus authentication line exceeds its limit")

    async def readexactly(self, size: int) -> bytes:
        return b"".join([await self.byte() for _ in range(size)])

    async def send(self, data: bytes) -> None:
        await asyncio.get_running_loop().sock_sendall(self.connection, data)


async def relay_bus_auth(
    caller: RawBusAuthentication,
    upstream: RawBusAuthentication,
    *,
    credentials: bytes | None = None,
    disable_fds: bool = False,
) -> None:
    async with asyncio.timeout(15):
        if credentials is None:
            credentials = await caller.byte()
        if credentials != b"\0":
            raise ValueError("missing session bus credentials byte")
        await upstream.send(credentials)
        while True:
            command = await caller.line()
            if disable_fds and command == b"NEGOTIATE_UNIX_FD\r\n":
                # Neither vsock nor the byte relay carries SCM_RIGHTS
                await caller.send(b"ERROR Unix FD passing is unavailable\r\n")
                continue
            await upstream.send(command)
            if command == b"BEGIN\r\n":
                return
            await caller.send(await upstream.line())


async def host_resource_bus_request(
    peer: socket.socket,
    address: str,
    registry_path: str,
) -> None:
    from portal.descriptors import IO_TIMEOUT, RegistryClient

    connection = registry = None
    auth = RawBusAuthentication(peer)

    async def byte_relay(credentials=None):
        await host_bus_request(peer, address, credentials=credentials)

    try:
        async with asyncio.timeout(15):
            first = await auth.byte()
            if first != b"\0":
                preface = first + await auth.readexactly(
                    len(RESOURCE_AUTH_PREFACE) - 1
                )
                if preface != RESOURCE_AUTH_PREFACE:
                    raise ValueError("unknown session bus resource preface")
        if first == b"\0":
            await byte_relay(first)
            return
        try:
            async with asyncio.timeout(IO_TIMEOUT):
                registry = await RegistryClient.connect(Path(registry_path))
                await registry.ping()
        except (OSError, ValueError, TimeoutError) as error:
            if registry is not None:
                registry.close()
                registry = None
            detail = (
                "registry readiness timed out"
                if isinstance(error, TimeoutError)
                else str(error)
            )
            print(
                f"WARNING: Portal descriptors unavailable: {detail}. "
                "Using the session bus byte relay.",
                file=sys.stderr,
            )
            await auth.send(RESOURCE_AUTH_DISABLED)
            await byte_relay()
            return
        await auth.send(RESOURCE_AUTH_ENABLED)
        connection = await connect_session_bus(address)
        await relay_descriptor_bus(connection, peer, "host", registry=registry)
    finally:
        if registry is not None:
            registry.close()
        if connection is not None:
            connection.close()


async def guest_resource_bus_request(
    connection: socket.socket, helper_path: str
) -> None:
    with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as upstream:
        upstream.setblocking(False)
        async with asyncio.timeout(15):
            await asyncio.get_running_loop().sock_connect(
                upstream, (socket.VMADDR_CID_HOST, BUS_PORT)
            )
            auth = RawBusAuthentication(upstream)
            await auth.send(RESOURCE_AUTH_PREFACE)
            response = await auth.readexactly(len(RESOURCE_AUTH_ENABLED))
        if response == RESOURCE_AUTH_ENABLED:
            await relay_descriptor_bus(
                connection, upstream, "guest", helper=Path(helper_path)
            )
        elif response == RESOURCE_AUTH_DISABLED:
            await relay_guest_bus(connection, upstream)
        else:
            raise ValueError("unknown session bus resource availability reply")


def find_session_bus(environment: Mapping[str, str]) -> str | None:
    if address := environment.get("DBUS_SESSION_BUS_ADDRESS"):
        try:
            unix_bus_addresses(address)
        except ValueError as error:
            print(
                f"WARNING: Session bus forwarding unavailable: {error}",
                file=sys.stderr,
            )
            return None
        return address
    path = runtime_directory(environment) / "bus"
    if path.is_socket():
        return "unix:path=" + quote_from_bytes(os.fsencode(path), safe="/._-")
    return None


def start_host_bus(
    runtime: Path,
    address: str,
    environment: Mapping[str, str],
    registry: Path | None = None,
) -> None:
    start_listener(
        channel_path(runtime, BUS_PORT),
        "host-bus-resources" if registry is not None else "host-bus",
        [address, str(registry)] if registry is not None else [address],
        environment,
    )


async def host_bus_request(
    connection: socket.socket,
    address: str,
    *,
    credentials: bytes | None = None,
) -> None:
    with await connect_session_bus(address) as upstream:
        await relay_bus_auth(
            RawBusAuthentication(connection),
            RawBusAuthentication(upstream),
            credentials=credentials,
            disable_fds=True,
        )
        async with (
            await UNIXSocketStream.from_socket(connection) as caller,
            await UNIXSocketStream.from_socket(upstream) as host,
        ):
            await relay_streams(caller, host, upstream_name="host session bus")


async def guest_bus_request(connection: socket.socket) -> None:
    with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as upstream:
        upstream.setblocking(False)
        async with asyncio.timeout(15):
            await asyncio.get_running_loop().sock_connect(
                upstream, (socket.VMADDR_CID_HOST, BUS_PORT)
            )
        await relay_guest_bus(connection, upstream)


async def relay_guest_bus(
    connection: socket.socket, upstream: socket.socket
) -> None:
    from resources import Namespace

    caller_pid = None
    namespace = None
    if connection.family == socket.AF_UNIX:
        pid, uid, _ = PEER_CREDENTIALS.unpack(
            connection.getsockopt(
                socket.SOL_SOCKET, socket.SO_PEERCRED, PEER_CREDENTIALS.size
            )
        )
        if pid > 0 and uid == os.geteuid():
            caller_pid = pid
            try:
                namespace = Namespace.from_socket(connection)
                if namespace.pid != caller_pid:
                    namespace.close()
                    namespace = None
                    raise ValueError("the socket creator identity changed")
            except (OSError, ValueError) as error:
                print(
                    f"WARNING: Caller file resources unavailable: {error}",
                    file=sys.stderr,
                )
    try:
        # Finish auth before asyncio can read ahead into binary or SCM_RIGHTS
        # The host still declines FD negotiation for the byte relay
        await relay_bus_auth(
            RawBusAuthentication(connection),
            RawBusAuthentication(upstream),
        )
        reader, writer = await asyncio.open_connection(
            sock=connection, limit=BUS_AUTH_LIMIT
        )
        writers = [writer]
        try:
            upstream_reader, upstream_writer = await asyncio.open_connection(
                sock=upstream, limit=BUS_AUTH_LIMIT
            )
            writers.append(upstream_writer)
            from portal.portal import MessageStream, relay_portal_messages

            await relay_portal_messages(
                MessageStream.from_streams(reader, writer),
                MessageStream.from_streams(upstream_reader, upstream_writer),
                caller_pid=caller_pid,
                namespace=namespace,
            )
        finally:
            await close_streams(*writers)
    finally:
        if namespace is not None:
            namespace.close()


def initialize_guest_bus() -> None:
    runtime = Path(os.environ["XDG_RUNTIME_DIR"])
    if not runtime.is_absolute():
        raise ValueError("guest XDG_RUNTIME_DIR must be absolute")
    role = "guest-bus"
    arguments = []
    if os.environ.get("STEAM_ASAHI_PORTAL_RESOURCES") == "1":
        from resource_transport import check_guest_resources

        try:
            helper = os.environ.get("STEAM_ASAHI_PIPEWIRE_BRIDGE")
            if not helper or not check_guest_resources(Path(helper)):
                raise ValueError(
                    "the PipeWire attachment helper is unavailable"
                )
        except (OSError, ValueError, TimeoutError) as error:
            print(
                f"WARNING: Guest portal descriptors unavailable: {error}. "
                "Using the session bus byte relay.",
                file=sys.stderr,
            )
        else:
            role = "guest-bus-resources"
            arguments = [helper]
    start_listener(
        runtime / BUS_SOCKET_NAME,
        role,
        arguments,
        os.environ,
        parent_pid=os.getppid(),
    )


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    if os.environ.get("STEAM_ASAHI_SESSION_BUS") == "1":
        initialize_guest_bus()
    if os.environ.get("STEAM_ASAHI_WAYLAND") == "1":
        try:
            initialize_guest_wayland(
                os.environ["STEAM_ASAHI_WAYPIPE"],
                os.environ["STEAM_ASAHI_KEEPER"],
            )
        except (OSError, ValueError) as error:
            print(
                f"WARNING: Guest Wayland bridge unavailable: {error}. "
                "Continuing with the X11 bridge.",
                file=sys.stderr,
            )
