"""Open guest links through the original host desktop session"""

from __future__ import annotations

import asyncio
import errno
import os
import re
import shlex
import shutil
import socket
import stat
import sys
from collections.abc import Mapping
from contextlib import closing, suppress
from pathlib import Path
from urllib.parse import urlsplit

if __name__ == "__main__":
    # Isolated mode needs the module directory before schema construction
    sys.path.insert(0, str(Path(__file__).resolve().parent))

from aiotools import TaskScope
from portal.rpc import RPC, capnp, connect, scoped

lazy from tenacity import (
    AsyncRetrying,
    retry_if_exception,
    stop_before_delay,
    wait_fixed,
)

lazy from transport import OPEN_PORT, channel_path, start_listener
lazy from resources import (
    MAX_ICON_BYTES,
    MAX_RESOURCE_REQUEST_BYTES,
    IconStore,
    file_uri,
    local_file_uri,
)

MAX_REQUEST_BYTES = MAX_RESOURCE_REQUEST_BYTES
ACTIVATION_VARIABLES = (
    ("activation_token", "XDG_ACTIVATION_TOKEN"),
    ("startup_id", "DESKTOP_STARTUP_ID"),
)
REQUEST_ENVIRONMENT_VARIABLES = ACTIVATION_VARIABLES + (
    ("parent_window", "PARENT_WINDOW_ID"),
)
STEAM_URI_SCHEMES = frozenset({"steam", "steamlink"})


def start_host_opener(
    runtime: Path, opener: str, environment: Mapping[str, str]
) -> None:
    start_listener(
        channel_path(runtime, OPEN_PORT), "open", [opener], environment
    )


class Desktop(RPC.Desktop.Server):
    def __init__(
        self, opener: str, icons: IconStore | None, tasks: TaskScope
    ) -> None:
        self.opener, self.icons = opener, icons
        self.calls = tasks
        self.owner = self
        self.operations = self.operation_bytes = 0
        self.byte_limit = MAX_REQUEST_BYTES

    @scoped
    async def health(self, **_):
        status = "available" if shutil.which(self.opener) else "missing"
        return status, self.opener

    @scoped
    async def resolve(self, target, mode, **_):
        from resources import resolve_host_uri

        if len(target.encode()) > MAX_REQUEST_BYTES:
            raise ValueError("file resource request is too large")
        resource = resolve_host_uri(target, mode)
        return resource["uri"], resource["kind"]

    @scoped
    async def cacheIcon(self, data, **_):
        if self.icons is None:
            raise ValueError("host notification icon storage is unavailable")
        if len(data) > MAX_ICON_BYTES:
            raise ValueError("notification icon exceeds the byte limit")
        return self.icons.put(data)

    @scoped
    async def open(self, target, environment, **_):
        if (
            not target
            or "\0" in target
            or not (
                Path(target).is_absolute()
                or re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", target)
            )
        ):
            raise ValueError("expected an absolute path or URI")
        if Path(target).is_absolute() and not Path(target).exists():
            raise FileNotFoundError("file is unavailable on the host")
        allowed = {name for _, name in REQUEST_ENVIRONMENT_VARIABLES}
        context = {variable.name: variable.value for variable in environment}
        if (
            len(environment) > len(allowed)
            or not context.keys() <= allowed
            or any("\0" in value for value in context.values())
            or sum(len(value.encode()) for value in [target, *context.values()])
            > MAX_REQUEST_BYTES
        ):
            raise ValueError("invalid desktop request context")
        inherited = {
            key: value
            for key, value in os.environ.items()
            if key not in allowed
        }
        process = await asyncio.create_subprocess_exec(
            self.opener, target, env=inherited | context
        )
        try:
            async with asyncio.timeout(30):
                status = await process.wait()
            return status if status >= 0 else 1
        finally:
            if process.returncode is None:
                with suppress(ProcessLookupError):
                    process.terminate()
                try:
                    await asyncio.wait_for(process.wait(), timeout=2)
                except TimeoutError:
                    with suppress(ProcessLookupError):
                        process.kill()
                    await process.wait()


async def open_request(
    connection: socket.socket, opener: str, *, icons: IconStore | None = None
) -> None:
    stream = await capnp.AsyncIoStream.create_connection(sock=connection)
    try:
        async with TaskScope(  # ty: ignore[invalid-context-manager]
            exception_handler=None
        ) as tasks:
            desktop = Desktop(opener, icons, tasks)
            server = capnp.TwoPartyServer(
                stream,
                bootstrap=desktop,
                traversal_limit_in_words=MAX_REQUEST_BYTES // 8,
            )
            desktop.rpc = server
            try:
                async with asyncio.timeout(40):
                    await server.on_disconnect()
            finally:
                server.close()
                tasks.abort()
    finally:
        stream.close()


def send_steam_uri(target: str) -> int:
    return asyncio.run(send_steam_uri_async(target))


async def send_steam_uri_async(target: str) -> int:
    # Match steam-runtime-urlopen's FIFO protocol so local Steam schemes
    # stay with the current guest client, including its isolated ARM64 HOME
    if any(character in target for character in ("\0", "\r", "\n")):
        print("ERROR: Steam URI contains a protocol delimiter", file=sys.stderr)
        return 1
    request = (
        shlex.join(["~/.steam/root/ubuntu12_32/steam", target]) + "\n"
    ).encode("utf-8")
    try:
        async for attempt in AsyncRetrying(
            retry=retry_if_exception(
                lambda error: (
                    isinstance(error, OSError)
                    and error.errno
                    in (errno.ENOENT, errno.ENXIO, errno.EAGAIN, errno.EPIPE)
                )
            ),
            wait=wait_fixed(0.05),
            stop=stop_before_delay(5),
            reraise=True,
        ):
            with attempt:
                descriptor = os.open(
                    Path.home() / ".steam/steam.pipe",
                    os.O_WRONLY | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOCTTY,
                )
                try:
                    if not stat.S_ISFIFO(os.fstat(descriptor).st_mode):
                        raise ValueError("Steam command pipe is not a FIFO")
                    # One bounded write keeps concurrent URI requests atomic
                    # A failed nonblocking write within PIPE_BUF delivers
                    # no bytes, so retries cannot duplicate a delivered request
                    if len(request) > os.fpathconf(descriptor, "PC_PIPE_BUF"):
                        raise ValueError(
                            "Steam URI is too long for its command pipe"
                        )
                    if os.write(descriptor, request) != len(request):
                        raise OSError("incomplete Steam command pipe write")
                finally:
                    os.close(descriptor)
    except (OSError, ValueError) as error:
        print(
            f"ERROR: Cannot send URI to guest Steam: {error}", file=sys.stderr
        )
        return 1
    return 0


def read_mounts(process: Path) -> list[list[str]]:
    with (process / "mountinfo").open(errors="surrogateescape") as mounts:
        return [
            [
                re.sub(
                    r"\\([0-7]{3})",
                    lambda match: chr(int(match[1], 8)),
                    field,
                )
                for field in line.rstrip("\n").split(" ")
            ]
            for line in mounts
        ]


def shared_mount_roots(mounts: list[list[str]]) -> dict[str, Path]:
    """Recover host paths for the root export and its automatic submounts"""
    entries = {fields[0]: fields for fields in mounts}
    roots: dict[str, Path] = {}
    locations: dict[str, Path] = {}
    remaining = list(mounts)
    while remaining:
        pending = []
        for fields in remaining:
            separator = fields.index("-", 6)
            filesystem, source = fields[separator + 1 : separator + 3]
            if filesystem != "virtiofs":
                continue
            device = fields[2]
            if source == "/dev/root":
                roots[device] = Path("/")
            elif source != "none":
                continue
            elif device not in roots:
                parent = entries.get(fields[1])
                location = locations.get(fields[1])
                if fields[3] != "/" or parent is None or location is None:
                    pending.append(fields)
                    continue
                roots[device] = location / Path(fields[4]).relative_to(
                    parent[4]
                )
            locations[fields[0]] = roots[device] / fields[3].removeprefix("/")
        if len(pending) == len(remaining):
            break
        remaining = pending
    return roots


def host_file_path(target: str) -> Path:
    from resources import Namespace

    with closing(Namespace.current()) as namespace:
        return namespace.host_path(Path(target).resolve(strict=True))


def host_open_target(target: str) -> str:
    if not re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", target):
        return str(host_file_path(target))
    uri = urlsplit(target)
    if uri.scheme.casefold() != "file":
        return target
    path, query, fragment = local_file_uri(target)
    return file_uri(host_file_path(str(path)), query, fragment)


def guest_open(arguments: list[str]) -> int:
    if (
        len(arguments) != 1
        or not arguments[0]
        or arguments[0] in ("--help", "--version")
    ):
        print("usage: xdg-open URI-or-file", file=sys.stderr)
        return 1
    target = arguments[0]
    scheme, separator, _ = target.partition(":")
    if separator and scheme.casefold() in STEAM_URI_SCHEMES:
        return send_steam_uri(target)
    try:
        target = host_open_target(target)
    except (OSError, ValueError) as error:
        print(
            f"ERROR: Cannot open this file on the host: {error}",
            file=sys.stderr,
        )
        return 1

    async def request():
        async with connect(OPEN_PORT, RPC.Desktop, timeout=40) as desktop:
            result = await desktop.open(
                target=target,
                environment=[
                    {"name": name, "value": os.environ[name]}
                    for _, name in REQUEST_ENVIRONMENT_VARIABLES
                    if name in os.environ
                ],
            )
            return result.status

    try:
        status = asyncio.run(capnp.run(request()))
        if status == 0:
            return 0
    except (OSError, ValueError, TimeoutError, capnp.KjException) as error:
        print(
            f"ERROR: Cannot contact host desktop opener: {error}",
            file=sys.stderr,
        )
        return 1
    print("ERROR: Host desktop could not open the URI or file", file=sys.stderr)
    return status if 0 < status < 256 else 1


if __name__ == "__main__":
    raise SystemExit(guest_open(sys.argv[1:]))
