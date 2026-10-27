"""Probe desktop services independently in each filesystem and bus namespace"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
from collections.abc import Mapping
from contextlib import redirect_stdout
from pathlib import Path

lazy from environment import runtime_directory, xdg_home
lazy from portal.protocol import DESCRIPTOR_METHODS, DESKTOP_SERVICES
lazy from resources import HOST_ROOT
lazy from session import connect_session_bus, find_session_bus
lazy from transport import OPEN_PORT
lazy from wayland import WAYLAND_SOCKET_NAME

DIAGNOSTIC_SCOPES = ("host", "guest", "runtime")
DESCRIPTOR_OPERATIONS = tuple(
    f"{interface.rsplit('.', 1)[-1]}.{member}"
    for interface, member, _signature in DESCRIPTOR_METHODS
)
BROKEN_STATUSES = frozenset({"transport-failed", "authentication-failed"})


def socket_probe(path: Path) -> dict[str, str]:
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(3)
            connection.connect(str(path))
    except FileNotFoundError:
        return {"status": "missing", "path": str(path)}
    except OSError as error:
        return {
            "status": "transport-failed",
            "path": str(path),
            "error": str(error),
        }
    return {"status": "reachable", "path": str(path)}


async def inspect_bus(address: str, result: dict[str, object]) -> None:
    from jeepney.auth import Authenticator, BEGIN, FDNegotiationError
    from jeepney.bus_messages import message_bus
    from jeepney.io.asyncio import DBusConnection, DBusRouter
    from jeepney.wrappers import unwrap_msg

    upstream = await connect_session_bus(address)
    try:
        reader, writer = await asyncio.open_connection(sock=upstream)
        async with DBusConnection(reader, writer) as connection:
            async with asyncio.timeout(5):
                result["connected_socket"] = os.fsdecode(upstream.getpeername())
                # Negotiation alone does not prove resource reconstruction
                # Never send descriptors or calls that return them here
                authenticator = Authenticator(enable_fds=True)
                try:
                    for request in authenticator:
                        writer.write(request)
                        await writer.drain()
                        reply = await reader.read(1024)
                        if not reply:
                            raise EOFError("bus closed during authentication")
                        authenticator.feed(reply)
                except FDNegotiationError:
                    result["descriptor_negotiation"] = "declined"
                else:
                    result["descriptor_negotiation"] = "supported"
                result["authentication"] = "EXTERNAL succeeded"
                writer.write(BEGIN)
                await writer.drain()
                async with DBusRouter(connection) as router:
                    unwrap_msg(
                        await router.send_and_get_reply(message_bus.Hello())
                    )
                    owned = set(
                        unwrap_msg(
                            await router.send_and_get_reply(
                                message_bus.ListNames()
                            )
                        )[0]
                    )
                    activatable = set(
                        unwrap_msg(
                            await router.send_and_get_reply(
                                message_bus.ListActivatableNames()
                            )
                        )[0]
                    )
                result["status"] = "ready"
                result["services"] = {
                    name: "running"
                    if name in owned
                    else "activatable"
                    if name in activatable
                    else "missing"
                    for name in DESKTOP_SERVICES
                }
    finally:
        upstream.close()


def bus_probe(address: str | None) -> dict[str, object]:
    from jeepney import DBusErrorResponse
    from jeepney.auth import AuthenticationError
    from jeepney.io.common import RouterClosed

    if address is None:
        return {"status": "missing", "authentication": "not-attempted"}
    result: dict[str, object] = {"address": address}
    try:
        asyncio.run(inspect_bus(address, result))
    except AuthenticationError as error:
        result.update(status="authentication-failed", authentication=str(error))
    except FileNotFoundError as error:
        result.update(status="missing", error=str(error))
    except (
        OSError,
        ValueError,
        EOFError,
        DBusErrorResponse,
        RouterClosed,
    ) as error:
        result.update(status="transport-failed", error=str(error))
    return result


def opener_probe(scope: str, opener: str | None) -> dict[str, object]:
    if scope == "host":
        return {
            "status": "available"
            if opener and shutil.which(opener) is not None
            else "missing",
            "executable": opener,
        }
    from portal.rpc import RPC, capnp, connect

    async def request():
        async with connect(OPEN_PORT, RPC.Desktop, timeout=5) as desktop:
            return (await desktop.health()).to_dict()

    try:
        return asyncio.run(capnp.run(request()))
    except (OSError, ValueError, TimeoutError, capnp.KjException) as error:
        return {"status": "transport-failed", "error": str(error)}


def desktop_report(scope: str, opener: str | None = None) -> dict[str, object]:
    runtime = runtime_directory()
    selected = os.environ.get("WAYLAND_DISPLAY")
    bridge = os.environ.get("STEAM_ASAHI_WAYLAND_DISPLAY", WAYLAND_SOCKET_NAME)
    display = os.environ.get("DISPLAY")
    report: dict[str, object] = {
        "scope": scope,
        "home": str(Path.home()),
        "runtime_directory": str(runtime),
        "selected_display": {"DISPLAY": display, "WAYLAND_DISPLAY": selected},
        "wayland": socket_probe(runtime / (selected or "wayland-0")),
        "session_bus": bus_probe(find_session_bus(os.environ)),
        "host_opener": opener_probe(scope, opener),
    }
    if scope != "host":
        report["wayland_bridge"] = socket_probe(runtime / bridge)
        bus = report["session_bus"]
        descriptor_status = "not-probed"
        reason = "The session bus is unavailable for descriptor negotiation"
        if isinstance(bus, Mapping) and bus.get("status") == "ready":
            if bus.get("descriptor_negotiation") == "supported":
                descriptor_status = "negotiated"
                reason = (
                    "Unix descriptor passing was negotiated; shared-file "
                    "identity and authorized stream reconstruction were not "
                    "exercised by this side-effect-free probe"
                )
            else:
                descriptor_status = "unsupported"
                reason = (
                    "The session-bus relay declined Unix descriptor passing"
                )
        report["descriptor_operations"] = {
            "status": descriptor_status,
            "operations": DESCRIPTOR_OPERATIONS,
            "reason": reason,
        }
    if display and (match := re.fullmatch(r":([0-9]+)(?:\.[0-9]+)?", display)):
        report["xwayland"] = socket_probe(
            Path("/tmp/.X11-unix") / ("X" + match[1])
        )
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scope", choices=DIAGNOSTIC_SCOPES, default="guest")
    parser.add_argument("--host-open")
    parser.add_argument("--runtime", type=Path)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    if arguments.output:
        with arguments.output.open("w", encoding="utf-8") as output:
            with redirect_stdout(output):
                return probe_namespace(arguments)
    return probe_namespace(arguments)


def probe_namespace(arguments) -> int:
    report = desktop_report(arguments.scope, arguments.host_open)
    print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
    broken = any(
        isinstance(value, Mapping) and value.get("status") in BROKEN_STATUSES
        for value in report.values()
    )
    status = int(broken)
    if arguments.runtime:
        entrypoint = arguments.runtime.resolve() / "_v2-entry-point"
        try:
            result = subprocess.run(
                [
                    str(entrypoint),
                    "--verb=run",
                    "--",
                    sys.executable,
                    "-I",
                    __file__,
                    "--scope=runtime",
                ],
                check=False,
                stdout=sys.stdout,
                timeout=90,
            )
            status |= int(result.returncode != 0)
        except (OSError, subprocess.TimeoutExpired) as error:
            print(
                json.dumps(
                    {
                        "scope": "runtime",
                        "status": "transport-failed",
                        "error": str(error),
                    }
                )
            )
            status = 1
    elif arguments.scope == "guest":
        print(
            json.dumps(
                {
                    "scope": "runtime",
                    "status": "not-probed",
                    "reason": "Pass --runtime /path/to/SteamLinuxRuntime_* to probe an installed container",
                }
            )
        )
    return status


def launch_diagnostics(
    configuration, arguments: list[str], configuration_file: Path
) -> int:
    from common import (
        LauncherError,
        exec_guest,
        muvm_arguments,
        steam_guest_environment,
    )

    parser = argparse.ArgumentParser(prog="steam-asahi --desktop-diagnostics")
    parser.add_argument("--runtime", type=Path)
    parser.add_argument("--host-only", action="store_true")
    parser.add_argument("--guest-output", type=Path, help=argparse.SUPPRESS)
    options = parser.parse_args(arguments)
    diagnostic = configuration.get("DESKTOP_DIAGNOSTIC")
    if not diagnostic:
        raise LauncherError("this package does not include desktop diagnostics")
    if options.guest_output is None:
        try:
            host = subprocess.run(
                [
                    diagnostic,
                    "--scope=host",
                    *(
                        ["--host-open", configuration["HOST_OPEN"]]
                        if configuration.get("HOST_OPEN")
                        else []
                    ),
                ],
                check=False,
                timeout=60,
            )
            host_status = int(host.returncode != 0)
        except subprocess.TimeoutExpired:
            print(
                json.dumps(
                    {
                        "scope": "host",
                        "status": "transport-failed",
                        "error": "host diagnostics timed out",
                    }
                )
            )
            host_status = 1
        if options.host_only:
            return host_status
        cache = xdg_home("XDG_CACHE_HOME") / "steam-asahi"
        cache.mkdir(mode=0o700, parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix="diagnostic-", dir=cache
        ) as directory:
            output = Path(directory) / "report.json"
            # muvm's primary console can disappear when stdin is a closed
            # pipe. Collect through the host-root export on first boot and
            # reuse, then print the same reports from the host process
            guest_output = Path(
                configuration.get("MUVM_HOST_MOUNT", str(HOST_ROOT))
            ) / output.relative_to("/")
            try:
                guest = subprocess.run(
                    [
                        sys.executable,
                        "-I",
                        str(Path(__file__).with_name("main.py")),
                        str(configuration_file),
                        "--desktop-diagnostics",
                        "--guest-output",
                        str(guest_output),
                        *(
                            ["--runtime", str(options.runtime.absolute())]
                            if options.runtime
                            else []
                        ),
                    ],
                    input=b"",
                    check=False,
                    timeout=180,
                )
                guest_status = int(guest.returncode != 0)
            except subprocess.TimeoutExpired:
                guest_status = 1
            if output.is_file():
                print(output.read_text(encoding="utf-8"), end="", flush=True)
            else:
                print(
                    json.dumps(
                        {
                            "scope": "guest",
                            "status": "transport-failed",
                            "error": "guest diagnostics did not produce a report",
                        }
                    )
                )
                guest_status = 1
            return host_status | guest_status
    command = [
        diagnostic,
        "--scope=guest",
        "--output",
        str(options.guest_output),
    ]
    if options.runtime:
        command.extend(["--runtime", str(options.runtime.absolute())])
    if configuration["BACKEND"] == "arm64":
        from arm64 import Arm64Launcher

        launcher = Arm64Launcher(configuration)
        launcher.initialize_environment()
        launcher.run_guest(command)
    exec_guest(
        muvm_arguments(
            configuration,
            steam_guest_environment(),
        )
        + ["--", *command],
        configuration=configuration,
    )


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    raise SystemExit(main())
