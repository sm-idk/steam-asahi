"""Readiness and lifetime management shared by desktop supervisors"""

from __future__ import annotations

import asyncio
import fcntl
import hashlib
import json
import os
import select
import signal
import socket
import subprocess
import sys
import time
from collections.abc import Mapping
from contextlib import ExitStack, aclosing, contextmanager, suppress
from pathlib import Path

import msgspec

lazy import psutil
lazy from aiotools import TaskContext
lazy from anyio import wait_readable

DESKTOP_IDENTITY_VARIABLES = (
    "HOME",
    "XDG_RUNTIME_DIR",
    "DBUS_SESSION_BUS_ADDRESS",
    "WAYLAND_DISPLAY",
    "DISPLAY",
    "XDG_CURRENT_DESKTOP",
)
SERVICE_STARTUP_TIMEOUT = 15
SERVICE_POLL_INTERVAL = 0.05
READY_MESSAGE = b"ready\n"


def service_identity(
    role: str, arguments: list[str], environment: Mapping[str, str]
) -> str:
    desktop = {key: environment.get(key) for key in DESKTOP_IDENTITY_VARIABLES}
    return hashlib.sha256(
        json.dumps([role, arguments, desktop], sort_keys=True).encode()
    ).hexdigest()


def service_status(path: Path) -> dict[str, object]:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(1)
        connection.connect(str(path) + ".control")
        with connection.makefile("rb") as stream:
            return msgspec.json.decode(
                stream.readline(4096), type=dict[str, object]
            )


@contextmanager
def service_lock(path: Path, identity: str):
    path.parent.mkdir(
        mode=0o700, parents=True, parent_mode=0o700, exist_ok=True
    )
    # Keep this inode after shutdown: unlinking locks lets two launchers
    # lock different inodes for the same port while muvm's allocator is using it
    with path.with_suffix(".lock").open("a+b") as lock:
        deadline = time.monotonic() + SERVICE_STARTUP_TIMEOUT
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                try:
                    status = service_status(path)
                except OSError, ValueError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError(
                            f"{path}: port is reserved but its broker is not "
                            "ready; close Steam and retry"
                        ) from None
                    time.sleep(SERVICE_POLL_INTERVAL)
                    continue
                if status.get("identity") != identity:
                    raise OSError(
                        f"{path}: desktop session changed; restart Steam"
                    )
                yield None
                return
        remove_service(path)
        yield lock


def start_supervisor(
    script: str,
    arguments: list[str | Path | int],
    environment: Mapping[str, str],
    *,
    pass_fds: tuple[int, ...],
    parent_pid: int | None = None,
) -> None:
    with ExitStack() as resources:
        # A pidfd follows exec without attaching to a reused PID
        parent = os.pidfd_open(
            os.getpid() if parent_pid is None else parent_pid
        )
        resources.callback(os.close, parent)
        ready, notification = os.pipe2(os.O_CLOEXEC)
        resources.callback(os.close, ready)
        notify = resources.enter_context(os.fdopen(notification, "wb"))
        process = subprocess.Popen(
            [
                sys.executable,
                "-I",
                script,
                str(parent),
                str(notification),
                *map(str, arguments),
            ],
            env=environment,
            pass_fds=(*pass_fds, parent, notification),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            start_new_session=True,
        )
        notify.close()
        wait_ready(process, ready)


def wait_ready(
    process: subprocess.Popen,
    descriptor: int,
    timeout: float = SERVICE_STARTUP_TIMEOUT,
) -> None:
    try:
        if not select.select([descriptor], [], [], timeout)[0]:
            raise TimeoutError("desktop helper startup timed out")
        status = os.read(descriptor, 4096)
        if status != READY_MESSAGE:
            raise OSError(
                status.decode("utf-8", errors="replace").strip()
                or "desktop supervisor exited before becoming ready"
            )
    except BaseException:
        with suppress(ProcessLookupError):
            process.terminate()
        try:
            process.wait(timeout=6)
        except subprocess.TimeoutExpired:
            # Supervisors own their groups, including all helper children
            with suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise


async def control_server(path: Path, identity: str) -> asyncio.Server:
    async def respond(reader, writer):
        try:
            writer.write(
                msgspec.json.encode({"identity": identity, "pid": os.getpid()})
                + b"\n"
            )
            await writer.drain()
        finally:
            writer.close()
            with suppress(ConnectionError):
                await writer.wait_closed()

    control = Path(str(path) + ".control")
    server = await asyncio.start_unix_server(respond, path=control)
    control.chmod(0o600)
    return server


def vm_running(path: Path) -> bool:
    try:
        with path.open("rb") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
    except FileNotFoundError:
        pass
    return False


async def watch_owner(
    parent_fd: int, stopped: asyncio.Event, vm_lock: Path | None
) -> None:
    async def parent_exit() -> None:
        await wait_readable(parent_fd)

    # The supervisor keeps the pidfd open until this scope has cancelled and
    # awaited its reader, so descriptor reuse cannot race readiness cleanup
    async with aclosing(TaskContext(exception_handler=None)) as tasks:
        parent_exited = tasks.create_task(parent_exit())
        seen_vm = False
        while not stopped.is_set():
            try:
                running = vm_lock is not None and vm_running(vm_lock)
            except OSError:
                stopped.set()
                return
            seen_vm |= running
            if not running and (seen_vm or parent_exited.done()):
                stopped.set()
                return
            # A forwarded muvm command can exit while the original VM lives
            # Continue watching the VM lock instead of that command's pidfd
            try:
                await asyncio.wait_for(stopped.wait(), timeout=0.5)
            except TimeoutError:
                pass


def remove_service(path: Path) -> None:
    path.unlink(missing_ok=True)
    Path(str(path) + ".control").unlink(missing_ok=True)


def group_members(group: int) -> list[int]:
    members = []
    for process in psutil.process_iter():
        if process.pid == os.getpid():
            continue
        try:
            if os.getpgid(process.pid) == group and process.status() not in (
                psutil.STATUS_ZOMBIE,
                psutil.STATUS_DEAD,
            ):
                members.append(process.pid)
        except OSError, psutil.Error:
            continue
    return members


async def stop_process_group() -> None:
    group = os.getpgrp()
    if group != os.getpid():
        raise RuntimeError("desktop supervisor must own its process group")
    os.killpg(group, signal.SIGTERM)
    deadline = asyncio.get_running_loop().time() + 5
    while members := group_members(group):
        if asyncio.get_running_loop().time() >= deadline:
            for pid in members:
                with suppress(ProcessLookupError):
                    descriptor = os.pidfd_open(pid)
                    try:
                        # The live supervisor keeps this PGID reserved. Use a
                        # pidfd so escalation cannot signal a reused worker PID
                        if pid in group_members(group):
                            signal.pidfd_send_signal(descriptor, signal.SIGKILL)
                    finally:
                        os.close(descriptor)
        # Retain the socket's allocator lock until every worker has exited,
        # even if Waypipe's leader exited before its connection handlers
        await asyncio.sleep(0.05)
