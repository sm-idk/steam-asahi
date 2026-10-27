"""Load the shared RPC schema and its dynamically exported extension API"""

from pathlib import Path
from contextlib import asynccontextmanager, closing
from functools import wraps
from typing import Any
import asyncio
import socket

import capnp as extension

from .protocol import MAX_REQUESTS

capnp: Any = extension
RPC = capnp.load(str(Path(__file__).with_name("resources.capnp")))


def scoped(method):
    """Bound incoming calls and await their cleanup with the owning connection"""

    @wraps(method)
    async def call(self, **arguments):
        owner = self.owner
        size = sum(len(arguments.get(key, b"")) for key in ("data", "manifest"))
        if (
            owner.operations >= MAX_REQUESTS * 3
            or owner.operation_bytes + size > owner.byte_limit
        ):
            owner.rpc.close()
            raise ValueError("too many pending desktop resource operations")
        owner.operations += 1
        owner.operation_bytes += size
        try:
            return await owner.calls.create_task(method(self, **arguments))
        finally:
            owner.operations -= 1
            owner.operation_bytes -= size

    return call


@asynccontextmanager
async def connect(port: int, interface, *, timeout: float = 10):
    with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as connection:
        connection.setblocking(False)
        async with asyncio.timeout(timeout):
            await asyncio.get_running_loop().sock_connect(
                connection, (socket.VMADDR_CID_HOST, port)
            )
            with (
                closing(
                    await capnp.AsyncIoStream.create_connection(sock=connection)
                ) as stream,
                closing(capnp.TwoPartyClient(stream)) as client,
            ):
                yield client.bootstrap().cast_as(interface)
