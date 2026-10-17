"""Select a desktop display for one game before its runtime container starts"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from pathlib import Path

lazy from wayland import WAYLAND_SOCKET_NAME
lazy from common import exit_status

PROTON_METADATA_FILES = ("version", "toolmanifest.vdf")
MAX_METADATA_CHARACTERS = 8192


def proton_info(directory: Path) -> None:
    directory = directory.resolve(strict=True)
    # Inspect the selected payload instead of assuming every Proton variant
    # recognizes the same driver switches or even includes the Wayland driver
    drivers = sorted(
        str(path.relative_to(directory))
        for path in directory.glob("**/winewayland.drv*")
        if path.is_file()
    )
    versions = {}
    for name in PROTON_METADATA_FILES:
        path = directory / name
        if path.is_file():
            with path.open(errors="replace") as metadata:
                versions[name] = metadata.read(MAX_METADATA_CHARACTERS).strip()
    print(
        json.dumps(
            {
                "proton": str(directory),
                "metadata": versions,
                "wayland_driver_files": drivers,
                "guidance": (
                    "Check this build's source, build configuration, and "
                    "runtime options before enabling its Wine Wayland driver; "
                    "driver files alone do not prove game compatibility"
                ),
            },
            ensure_ascii=False,
            indent=2,
        )
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--wayland", action="store_true")
    selection.add_argument("--xwayland", action="store_true")
    parser.add_argument(
        "--display", help="Wayland socket name or absolute path"
    )
    parser.add_argument(
        "--clear-display",
        action="store_true",
        help="clear DISPLAY for this command, for Wine builds that require it",
    )
    parser.add_argument("--proton-info", type=Path)
    parser.add_argument(
        "--inhibit",
        choices=("idle", "idle-suspend"),
        help="hold a host portal inhibitor only while this game command runs",
    )
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    if arguments.proton_info:
        proton_info(arguments.proton_info)
        return 0
    command = arguments.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("a game command is required")
    if arguments.clear_display and not arguments.wayland:
        parser.error("--clear-display requires --wayland")
    if arguments.display and not arguments.wayland:
        parser.error("--display requires --wayland")
    environment = os.environ.copy()
    if arguments.wayland:
        display = arguments.display or environment.get(
            "STEAM_ASAHI_WAYLAND_DISPLAY", WAYLAND_SOCKET_NAME
        )
        runtime = environment.get("XDG_RUNTIME_DIR")
        if not Path(display).is_absolute() and not runtime:
            parser.error("XDG_RUNTIME_DIR is required for relative displays")
        path = Path(runtime or "/") / display
        if not path.is_socket():
            parser.error(
                f"Wayland display {path} is unavailable; run desktop "
                "diagnostics or restart Steam"
            )
        environment["WAYLAND_DISPLAY"] = display
        environment.pop("WAYLAND_SOCKET", None)
        if arguments.clear_display:
            environment.pop("DISPLAY", None)
    elif arguments.xwayland:
        if not environment.get("DISPLAY"):
            parser.error("the inherited XWayland DISPLAY is unavailable")
        environment.pop("WAYLAND_DISPLAY", None)
        environment.pop("WAYLAND_SOCKET", None)
    if arguments.inhibit:
        from gi.events import GLibEventLoop

        from inhibition import run_inhibited

        status = asyncio.run(
            run_inhibited(
                command, environment, arguments.inhibit == "idle-suspend"
            ),
            loop_factory=GLibEventLoop,
        )
        return exit_status(status)
    os.execvpe(command[0], command, environment)
    return 1


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1) from error
