"""Provide an optional guest display through matching Waypipe processes"""

from __future__ import annotations

import asyncio
import json
import os
import signal
import sys
from collections.abc import Mapping
from pathlib import Path
from contextlib import aclosing

lazy from aiotools import TaskContext, race

lazy from environment import runtime_directory

lazy from transport import channel_path
lazy from services import (
    control_server,
    READY_MESSAGE,
    remove_service,
    service_identity,
    service_lock,
    stop_process_group,
    start_supervisor,
    watch_owner,
)

WAYLAND_PORT = 50197
# Pressure Vessel preserves names beginning with wayland- when importing sockets
WAYLAND_SOCKET_NAME = "wayland-steam-asahi"


def find_wayland_display(environment: Mapping[str, str]) -> Path | None:
    display = environment.get("WAYLAND_DISPLAY", "wayland-0")
    if not display:
        return None
    path = runtime_directory(environment) / display
    return path if path.is_socket() else None


def start_waypipe(
    path: Path,
    arguments: list[str],
    environment: Mapping[str, str],
    *,
    parent_pid: int | None = None,
    display: Path | None = None,
) -> None:
    identity = service_identity("waypipe", arguments, environment)
    with service_lock(path, identity) as lock:
        if lock is None:
            return
        try:
            start_supervisor(
                __file__,
                [
                    lock.fileno(),
                    path,
                    json.dumps(arguments),
                    identity,
                    str(display) if display is not None else "",
                    "host" if parent_pid is None else "guest",
                ],
                environment,
                pass_fds=(lock.fileno(),),
                parent_pid=parent_pid,
            )
        except BaseException:
            remove_service(path)
            raise


async def supervise_waypipe(
    path: Path,
    parent_fd: int,
    notification_fd: int,
    arguments: list[str],
    identity: str,
    display: Path | None,
    host: bool,
) -> None:
    if os.getpgrp() != os.getpid():
        raise RuntimeError("Waypipe supervisor must own its process group")
    loop = asyncio.get_running_loop()
    stopped = asyncio.Event()
    loop.add_signal_handler(signal.SIGTERM, stopped.set)
    process: asyncio.subprocess.Process | None = None
    notified = False
    control: asyncio.Server | None = None

    async def watch_display() -> None:
        original = display.stat() if display is not None else None
        while True:
            await asyncio.sleep(2)
            try:
                current = display.stat() if display is not None else None
                if (
                    original
                    and current
                    and (original.st_dev, original.st_ino)
                    == (current.st_dev, current.st_ino)
                ):
                    continue
            except OSError:
                pass
            print(
                "WARNING: Host compositor changed or logged out; "
                "restart Steam to reconnect its Wayland display",
                file=sys.stderr,
            )
            stopped.set()
            return

    async with aclosing(TaskContext(exception_handler=None)) as tasks:
        tasks.create_task(
            watch_owner(
                parent_fd,
                stopped,
                path.parents[2] / "muvm.lock" if host else None,
            )
        )
        try:
            # This supervisor owns its process group. Keep Waypipe's connection
            # handlers and keeper in that group so shutdown reaches every child
            process = await asyncio.create_subprocess_exec(*arguments)
            deadline = loop.time() + 10
            while not path.is_socket():
                if process.returncode is not None or stopped.is_set():
                    raise OSError("Waypipe exited before creating its socket")
                if loop.time() >= deadline:
                    raise TimeoutError("Waypipe socket startup timed out")
                await asyncio.sleep(0.05)
            path.chmod(0o600)
            control = await control_server(path, identity)
            if display is not None:
                tasks.create_task(watch_display())
            os.write(notification_fd, READY_MESSAGE)
            notified = True
            await race((stopped.wait(), process.wait()))
            if not stopped.is_set():
                print(
                    f"WARNING: Waypipe exited with status {process.returncode}",
                    file=sys.stderr,
                )
        except (OSError, ValueError) as error:
            if not notified:
                os.write(
                    notification_fd, str(error).encode("utf-8")[:4000] + b"\n"
                )
            else:
                print(f"WARNING: Waypipe failed: {error}", file=sys.stderr)
        finally:
            if control is not None:
                control.close()
                await control.wait_closed()
            if process is not None:
                await stop_process_group()
                await process.wait()
            remove_service(path)


def start_host_wayland(
    runtime: Path,
    waypipe: str,
    display: Path,
    environment: Mapping[str, str],
    options: list[str],
) -> None:
    path = channel_path(runtime, WAYLAND_PORT)
    start_waypipe(
        path,
        [
            waypipe,
            *options,
            "--socket",
            str(path),
            "client",
        ],
        dict(environment) | {"WAYLAND_DISPLAY": str(display)},
        display=display,
    )


def initialize_guest_wayland(waypipe: str, keeper: str) -> None:
    runtime = Path(os.environ["XDG_RUNTIME_DIR"])
    path = runtime / WAYLAND_SOCKET_NAME
    start_waypipe(
        path,
        [
            waypipe,
            *json.loads(
                Path(os.environ["STEAM_ASAHI_WAYPIPE_ARGS_FILE"]).read_text()
            ),
            "--vsock",
            "--socket",
            f"2:{WAYLAND_PORT}",
            "--display",
            WAYLAND_SOCKET_NAME,
            "server",
            "--",
            keeper,
            "infinity",
        ],
        os.environ,
        parent_pid=os.getppid(),
    )


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    with (
        os.fdopen(int(sys.argv[3]), "ab"),
        os.fdopen(int(sys.argv[1]), "rb"),
        os.fdopen(int(sys.argv[2]), "wb"),
    ):
        asyncio.run(
            supervise_waypipe(
                Path(sys.argv[4]),
                int(sys.argv[1]),
                int(sys.argv[2]),
                json.loads(sys.argv[5]),
                sys.argv[6],
                Path(sys.argv[7]) if sys.argv[7] else None,
                sys.argv[8] == "host",
            )
        )
