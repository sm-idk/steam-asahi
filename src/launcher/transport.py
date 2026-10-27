"""Supervise private Unix listeners used by muvm's vsock channels"""

from __future__ import annotations

import asyncio
import os
import socket
import signal
import sys
from collections.abc import Awaitable, Callable, Mapping
from contextlib import ExitStack, aclosing
from dataclasses import dataclass
from functools import partial
from pathlib import Path

lazy from aiotools import TaskContext, TaskScope, race
lazy from anyio import BrokenResourceError, ClosedResourceError
lazy from anyio.abc import ByteStream

lazy from services import (
    control_server,
    READY_MESSAGE,
    remove_service,
    service_identity,
    service_lock,
    start_supervisor,
    watch_owner,
)

# muvm 0.7 reserves its dynamic ports with the corresponding .lock file
OPEN_PORT = 50199
BUS_PORT = 50198
LISTENER_BACKLOG = 64
MAX_CONNECTIONS = 256


@dataclass(frozen=True)
class ListenerRole:
    handler: Callable[..., Awaitable[None]]
    watch_vm: bool = True
    cache_icons: bool = False


def channel_path(runtime: Path, port: int) -> Path:
    return runtime / f"krun/socket/port-{port}"


def start_listener(
    path: Path,
    role: str,
    arguments: list[str],
    environment: Mapping[str, str],
    *,
    parent_pid: int | None = None,
) -> None:
    identity = service_identity(role, arguments, environment)
    with service_lock(path, identity) as lock:
        if lock is None:
            return
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(str(path))
                path.chmod(0o600)
                listener.listen(LISTENER_BACKLOG)
                start_supervisor(
                    __file__,
                    [
                        listener.fileno(),
                        lock.fileno(),
                        path,
                        role,
                        identity,
                        *arguments,
                    ],
                    environment,
                    pass_fds=(listener.fileno(), lock.fileno()),
                    parent_pid=parent_pid,
                )
        except BaseException:
            remove_service(path)
            raise


async def relay_streams(
    first: ByteStream,
    second: ByteStream,
    *,
    upstream_name: str | None = None,
) -> None:
    client_closed = False

    async def copy(
        source: ByteStream,
        destination: ByteStream,
        upstream: bool,
    ) -> None:
        nonlocal client_closed
        async for data in source:
            await destination.send(data)
        if not upstream:
            client_closed = True
        elif upstream_name and not client_closed:
            print(
                f"WARNING: {upstream_name} disconnected; new requests will "
                "reconnect, but restart Steam if existing clients fail",
                file=sys.stderr,
            )
        await destination.send_eof()

    async with aclosing(TaskContext(exception_handler=None)) as tasks:
        # Drain both directions on half-close; cancel the peer on errors
        first_copy = tasks.create_task(copy(first, second, False))
        second_copy = tasks.create_task(copy(second, first, True))
        try:
            await asyncio.gather(first_copy, second_copy)
        except BrokenResourceError, ClosedResourceError:
            pass


async def close_streams(*writers: asyncio.StreamWriter) -> None:
    for writer in writers:
        writer.close()
    await asyncio.gather(
        *(writer.wait_closed() for writer in writers), return_exceptions=True
    )


async def serve(
    listener: socket.socket,
    parent_fd: int,
    role: str,
    arguments: list[str],
    path: Path,
    notification: int,
    identity: str,
) -> None:
    from desktop import open_request
    from resources import IconStore
    from portal.rpc import capnp
    from session import (
        guest_bus_request,
        guest_resource_bus_request,
        host_bus_request,
        host_resource_bus_request,
    )

    roles = {
        "open": ListenerRole(open_request, cache_icons=True),
        "host-bus": ListenerRole(host_bus_request),
        "guest-bus": ListenerRole(guest_bus_request, watch_vm=False),
        "host-bus-resources": ListenerRole(host_resource_bus_request),
        "guest-bus-resources": ListenerRole(
            guest_resource_bus_request, watch_vm=False
        ),
    }
    if role not in roles:
        raise ValueError(f"unknown transport role: {role}")
    service = roles[role]
    stopped = asyncio.Event()
    asyncio.get_running_loop().add_signal_handler(signal.SIGTERM, stopped.set)
    connections: set[asyncio.Task] = set()
    failure = None

    def failed(context):
        nonlocal failure
        failure = context["exception"]
        stopped.set()

    async def handle(connection: socket.socket) -> None:
        try:
            await handler(connection, *arguments)
        except (
            OSError,
            ValueError,
            TimeoutError,
            asyncio.IncompleteReadError,
            asyncio.LimitOverrunError,
            capnp.KjException,
        ) as error:
            print(
                f"WARNING: Desktop transport failed: {error}", file=sys.stderr
            )
        finally:
            connection.close()

    async def accept() -> None:
        # Raw accepts leave ancillary descriptors untouched until a role
        # explicitly selects either the Unix FD receiver or a byte transport
        listener.setblocking(False)
        while True:
            connection, _ = await asyncio.get_running_loop().sock_accept(
                listener
            )
            if len(connections) >= MAX_CONNECTIONS:
                connection.close()
                continue
            try:
                task = tasks.create_task(handle(connection))
            except BaseException:
                connection.close()
                raise
            connections.add(task)
            task.add_done_callback(connections.discard)

    with ExitStack() as resources:
        handler = service.handler
        if service.cache_icons:
            try:
                icons = resources.enter_context(IconStore(path.parents[2]))
            except OSError as error:
                print(
                    f"WARNING: Notification icon cache unavailable: {error}",
                    file=sys.stderr,
                )
            else:
                handler = partial(handler, icons=icons)
        # Cached icons outlive all request tasks, including cancelled requests
        async with (
            capnp.kj_loop(),
            TaskScope(exception_handler=failed) as tasks,  # ty: ignore[invalid-context-manager]
        ):
            tasks.create_task(
                watch_owner(
                    parent_fd,
                    stopped,
                    path.parents[2] / "muvm.lock" if service.watch_vm else None,
                )
            )
            async with await control_server(path, identity) as control:
                try:
                    os.write(notification, READY_MESSAGE)
                    os.close(notification)
                    await race([accept(), stopped.wait()])
                    if failure is not None:
                        raise failure
                finally:
                    listener.close()
                    control.close()
                    control.abort_clients()
                    tasks.abort()


if __name__ == "__main__":
    # Isolated Python excludes the script directory from its import path
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    socket_path = Path(sys.argv[5])
    with (
        socket.socket(fileno=int(sys.argv[3])) as service_listener,
        os.fdopen(int(sys.argv[4]), "ab"),
        os.fdopen(int(sys.argv[1]), "rb"),
    ):
        try:
            asyncio.run(
                serve(
                    service_listener,
                    int(sys.argv[1]),
                    sys.argv[6],
                    sys.argv[8:],
                    socket_path,
                    int(sys.argv[2]),
                    sys.argv[7],
                )
            )
        finally:
            remove_service(socket_path)
