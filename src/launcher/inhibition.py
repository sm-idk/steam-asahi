"""Hold a portal inhibitor for the lifetime of a single game command"""

from __future__ import annotations

import asyncio
import os
import signal
import sys
from collections.abc import Mapping
from contextlib import suppress

import gi
from aiotools import race

from portal.protocol import PORTAL

# GObject namespaces are loaded from the packaged typelibs at runtime
lazy from gi.repository import Gio, GLib, Xdp  # ty: ignore[unresolved-import]

gi.require_version("Xdp", "1.0")

PORTAL_CLOSE_TIMEOUT = 2
FORWARDED_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)


async def run_inhibited(
    command: list[str], environment: Mapping[str, str], suspend: bool
) -> int:
    connection = None
    portal = None
    handle = None
    watch = None
    process: asyncio.subprocess.Process | None = None
    loop = asyncio.get_running_loop()
    pending_signals: list[int] = []
    disconnected = asyncio.Event()
    observed = asyncio.Event()
    generation = 0

    def forward(signum: int) -> None:
        if process is None:
            pending_signals.append(signum)
        elif process.returncode is None:
            with suppress(ProcessLookupError):
                os.killpg(process.pid, signum)

    def vanished(*_) -> None:
        nonlocal generation
        generation += 1
        observed.set()
        if handle is not None:
            disconnected.set()

    async def close_bus() -> None:
        nonlocal connection
        if connection is not None:
            with suppress(GLib.Error, TimeoutError):
                async with asyncio.timeout(PORTAL_CLOSE_TIMEOUT):
                    await connection.close()
            connection = None

    for signum in FORWARDED_SIGNALS:
        loop.add_signal_handler(signum, forward, signum)
    try:
        try:
            async with asyncio.timeout(10):
                bus = await Gio.bus_get(Gio.BusType.SESSION)
                connection = bus
                # The game must keep running if the host session bus dies
                bus.set_exit_on_close(False)
                bus.connect("closed", lambda *_: disconnected.set())
                watch = Gio.bus_watch_name_on_connection(
                    bus,
                    PORTAL,
                    Gio.BusNameWatcherFlags.NONE,
                    lambda *_: observed.set(),
                    vanished,
                )
                await observed.wait()
                before = generation
                portal = Xdp.Portal.initable_new()
                flags = Xdp.InhibitFlags.IDLE
                if suspend:
                    flags |= Xdp.InhibitFlags.SUSPEND
                # libportal owns handle tokens, early Response signals, and
                # Request.Close on cancellation and explicit uninhibition
                handle = await portal.session_inhibit(
                    None, "Playing a Steam game", flags
                )
                if generation != before:
                    disconnected.set()
        except (GLib.Error, OSError, ValueError, TimeoutError) as error:
            print(
                f"WARNING: Game idle inhibition unavailable: {error}",
                file=sys.stderr,
            )
            # Drop failed requests before the game can outlive their cleanup
            await close_bus()
        if pending_signals:
            return -pending_signals[0]
        process = await asyncio.create_subprocess_exec(
            *command, env=environment, start_new_session=True
        )
        for signum in pending_signals:
            forward(signum)
        pending_signals.clear()
        if handle is None:
            return await process.wait()

        async def warn_disconnect() -> int:
            await disconnected.wait()
            if process.returncode is None:
                print(
                    "WARNING: Host portal or session bus disconnected; game "
                    "inhibition was released. Restart the game to reacquire "
                    "inhibition",
                    file=sys.stderr,
                )
            return await process.wait()

        status, _ = await race((process.wait(), warn_disconnect()))
        return status
    finally:
        if process is not None and process.returncode is None:
            forward(signal.SIGTERM)
            try:
                await asyncio.wait_for(process.wait(), timeout=5)
            except TimeoutError:
                forward(signal.SIGKILL)
                await process.wait()
        if watch is not None:
            Gio.bus_unwatch_name(watch)
        if handle is not None and portal is not None:
            portal.session_uninhibit(handle)
        # Disconnect also drops inhibitors if Request.Close cannot finish
        await close_bus()
        for signum in FORWARDED_SIGNALS:
            loop.remove_signal_handler(signum)
