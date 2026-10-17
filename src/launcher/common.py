"""Host file and process helpers shared by both Steam launchers"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from collections.abc import Mapping
from contextlib import suppress
from pathlib import Path
from typing import TYPE_CHECKING, NoReturn
from uuid import uuid4

lazy from environment import runtime_directory

lazy from boltons.fileutils import atomic_save
lazy from desktop import start_host_opener
lazy from resources import HOST_ROOT
lazy from services import vm_running
lazy from session import BUS_SOCKET_NAME, find_session_bus, start_host_bus
lazy from wayland import (
    WAYLAND_SOCKET_NAME,
    find_wayland_display,
    start_host_wayland,
)

if TYPE_CHECKING:
    from configuration import LauncherConfiguration

PRESSURE_VESSEL_FILESYSTEMS_RO = "/nix:/run/opengl-driver"
STEAM_CLIENT_ARGS = ("-cef-force-occlusion",)
HOST_LOCALE_VARIABLES = (
    "LANGUAGE",
    "LC_ADDRESS",
    "LC_COLLATE",
    "LC_CTYPE",
    "LC_IDENTIFICATION",
    "LC_MEASUREMENT",
    "LC_MESSAGES",
    "LC_MONETARY",
    "LC_NAME",
    "LC_NUMERIC",
    "LC_PAPER",
    "LC_TELEPHONE",
    "LC_TIME",
)


class LauncherError(RuntimeError):
    """The launcher cannot safely prepare or start Steam"""


def executable(path: Path) -> bool:
    return path.is_file() and os.access(path, os.X_OK)


def run(*arguments: str | Path) -> None:
    subprocess.run(arguments, check=True)


def steam_directory(home: Path, data_home: Path) -> Path:
    link = home / ".steam/steam"
    if link.exists(follow_symlinks=False):
        return link.resolve()
    return data_home / "Steam"


def copy_bootstrap(source: str, destination: Path) -> None:
    # Preserve archive metadata and merge partial installs using coreutils
    destination.mkdir(parents=True, exist_ok=True)
    run("cp", "--archive", "--no-target-directory", "--", source, destination)
    run("chmod", "-RP", "u+rwX", "--", destination)


def install_client_bootstrap(
    source: str, destination: Path, architecture: str
) -> None:
    if not executable(destination / "steam"):
        print(f"Installing the pinned {architecture} Steam beta bootstrap...")
        copy_bootstrap(source, destination)


def configure_steam_state(
    home: Path, steam: Path, channel: str, links: Mapping[str, Path]
) -> None:
    beta = steam / "package/beta"
    beta.parent.mkdir(parents=True, exist_ok=True)
    write_managed_value(beta, channel)
    directory = home / ".steam"
    directory.mkdir(parents=True, exist_ok=True)
    for name, target in links.items():
        link = directory / name
        if not link.exists(follow_symlinks=False):
            link.symlink_to(target)


def steam_guest_environment() -> dict[str, str]:
    return {
        "PRESSURE_VESSEL_FILESYSTEMS_RO": PRESSURE_VESSEL_FILESYSTEMS_RO,
        "STEAM_ASAHI_GUEST_UID": str(os.geteuid()),
    }


def acquire_steam_lock(steam: Path, mode: int) -> int:
    steam.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(
        steam / ".steam-asahi.lock", os.O_RDWR | os.O_CREAT, mode
    )
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor


def exit_status(status: int) -> int:
    """Preserve a child process's signal termination at the launcher boundary"""
    if status < 0:
        signum = -status
        if signum not in (signal.SIGKILL, signal.SIGSTOP):
            signal.signal(signum, signal.SIG_DFL)
        signal.raise_signal(signum)
    return status


def install_managed_file(
    source: str | Path, destination: Path, mode: int
) -> None:
    with (
        Path(source).open("rb") as source_file,
        atomic_save(
            destination, file_perms=mode, part_file=f".{uuid4().hex}"
        ) as destination_file,
    ):
        shutil.copyfileobj(source_file, destination_file)


def write_managed_value(destination: Path, value: str) -> None:
    content = f"{value}\n".encode("utf-8")
    with suppress(FileNotFoundError):
        if destination.read_bytes() == content:
            return
    with atomic_save(
        destination, file_perms=0o600, part_file=f".{uuid4().hex}"
    ) as destination_file:
        destination_file.write(content)


def replace_symlink(target: str | Path, destination: Path) -> None:
    # GNU ln refuses to replace directories and replaces symlinks themselves
    run(
        "ln",
        "--symbolic",
        "--force",
        "--no-target-directory",
        "--",
        target,
        destination,
    )


def muvm_arguments(
    configuration: LauncherConfiguration,
    environment: Mapping[str, str],
    *,
    emulator: str | None = None,
    interactive: bool = True,
) -> list[str]:
    if configuration.get("GUEST_SESSION"):
        # Pressure Vessel needs the same host export for chooser replies,
        # including host document-portal mounts and new save destinations
        environment = dict(environment)
        shared = environment.get("PRESSURE_VESSEL_FILESYSTEMS_RW")
        if shared is None:
            shared = os.environ.get("PRESSURE_VESSEL_FILESYSTEMS_RW", "")
        environment["PRESSURE_VESSEL_FILESYSTEMS_RW"] = ":".join(
            part for part in (shared, str(HOST_ROOT)) if part
        )
    return [
        configuration["MUVM"],
        *([f"--emu={emulator}"] if emulator is not None else []),
        "--gpu-mode=drm",
        *configuration["CPU_ARGS"],
        *configuration["MEMORY_ARGS"],
        *configuration["VRAM_ARGS"],
        *configuration["NETWORK_ARGS"],
        "--execute-pre",
        configuration["INIT_SCRIPT"],
        *(["--interactive"] if interactive else []),
        *[*("-e", f"{name}={value}") for name, value in environment.items()],
    ]


def exec_guest(
    arguments: list[str],
    lock_descriptor: int | None = None,
    *,
    configuration: LauncherConfiguration,
    reuse_only: bool = False,
    host_environment: Mapping[str, str] | None = None,
) -> NoReturn:
    environment = os.environ.copy()
    environment.pop("MUVM_RUNTIME_DIR", None)
    environment.pop("KRUN_PIPEWIRE_REGISTRY", None)
    if display := environment.get("DISPLAY"):
        if re.fullmatch(r":[0-9]+\.[0-9]+", display):
            # libkrun and muvm's Xauthority filter expect the display number
            # without Xlib's optional screen suffix
            environment["DISPLAY"] = display.split(".", 1)[0]
    default_runtime = Path(f"/run/user/{os.geteuid()}")
    if not environment.get("XDG_RUNTIME_DIR") and default_runtime.is_dir():
        environment["XDG_RUNTIME_DIR"] = str(default_runtime)
    desktop_environment = dict(
        host_environment if host_environment is not None else os.environ
    )
    if not desktop_environment.get("XDG_RUNTIME_DIR"):
        if host_runtime := environment.get("XDG_RUNTIME_DIR"):
            desktop_environment["XDG_RUNTIME_DIR"] = host_runtime
    session_bus = (
        find_session_bus(desktop_environment)
        if configuration.get("GUEST_SESSION")
        else None
    )
    wayland_display = (
        find_wayland_display(desktop_environment)
        if configuration.get("GUEST_SESSION") and configuration.get("WAYPIPE")
        else None
    )
    if runtime := environment.get("XDG_RUNTIME_DIR"):
        if not Path(runtime).is_absolute():
            raise LauncherError("XDG_RUNTIME_DIR must be an absolute path")
        try:
            runtime.encode("utf-8")
        except UnicodeEncodeError as error:
            raise LauncherError(
                "XDG_RUNTIME_DIR must be valid UTF-8"
            ) from error
        # muvm reuses a VM without rerunning init or applying boot options
        # Include the home because ARM64 init rewrites the guest passwd entry
        identity = json.dumps(
            [
                configuration,
                str(Path.home()),
                session_bus,
                str(wayland_display) if wayland_display else None,
            ],
            sort_keys=True,
        ).encode()
        instance = hashlib.sha256(identity).hexdigest()[:16]
        directory = Path(runtime) / "steam-asahi" / instance
        directory.mkdir(
            mode=0o700, parents=True, parent_mode=0o700, exist_ok=True
        )
        # Upstream muvm uses XDG_RUNTIME_DIR for its locks and control
        # sockets muvm uses this host-side alias to discover the audio socket
        replace_symlink(Path(runtime) / "pulse", directory / "pulse")
        # libkrun discovers PipeWire separately, but resolves Wayland under XDG
        environment.setdefault("PIPEWIRE_RUNTIME_DIR", runtime)
        display = environment.get("WAYLAND_DISPLAY", "wayland-0")
        if display:
            # libkrun 1.19 prefixes the runtime directory even for absolute
            # display paths, so always provide a simple private socket alias
            replace_symlink(Path(runtime) / display, directory / "wayland-host")
            environment["WAYLAND_DISPLAY"] = "wayland-host"
        environment["XDG_RUNTIME_DIR"] = str(directory)
    if reuse_only:
        # A held Steam lock can belong to a VM from another configuration
        # Refuse to boot a second VM against that same mutable Steam home
        runtime = environment.get("XDG_RUNTIME_DIR")
        running = vm_running(Path(runtime) / "muvm.lock") if runtime else False
        if not running:
            raise LauncherError(
                "Steam Asahi is already running with another launcher "
                "configuration; close Steam before using this launcher"
            )
    if opener := configuration.get("HOST_OPEN"):
        if not environment.get("XDG_RUNTIME_DIR"):
            raise LauncherError("desktop integration requires XDG_RUNTIME_DIR")
        start_host_opener(
            Path(environment["XDG_RUNTIME_DIR"]),
            str(opener),
            desktop_environment,
        )
    if (session_bus or wayland_display) and (
        guest_session := configuration.get("GUEST_SESSION")
    ):
        if not environment.get("XDG_RUNTIME_DIR"):
            raise LauncherError(
                "guest desktop services require XDG_RUNTIME_DIR"
            )
        guest_environment = {}
        if session_bus:
            registry = None
            guest_environment["STEAM_ASAHI_PORTAL_RESOURCES"] = "0"
            if configuration.get("PORTAL_RESOURCES", False):
                registry_directory = (
                    Path(environment["XDG_RUNTIME_DIR"]) / "portal"
                )
                try:
                    registry_directory.mkdir(mode=0o700, exist_ok=True)
                except OSError as error:
                    print(
                        f"WARNING: Portal resource directory unavailable: "
                        f"{error}. Using the session bus byte relay.",
                        file=sys.stderr,
                    )
                else:
                    registry = registry_directory / "pipewire"
                    environment["KRUN_PIPEWIRE_REGISTRY"] = str(registry)
                    guest_environment["STEAM_ASAHI_PORTAL_RESOURCES"] = "1"
            start_host_bus(
                Path(environment["XDG_RUNTIME_DIR"]),
                session_bus,
                desktop_environment,
                registry=registry,
            )
            guest_environment.update(
                STEAM_ASAHI_SESSION_BUS="1",
                DBUS_SESSION_BUS_ADDRESS="unix:path="
                f"/run/user/{os.geteuid()}/{BUS_SOCKET_NAME}",
            )
        if wayland_display:
            try:
                start_host_wayland(
                    Path(environment["XDG_RUNTIME_DIR"]),
                    str(configuration["WAYPIPE"]),
                    wayland_display,
                    desktop_environment,
                    configuration.get("WAYPIPE_ARGS", []),
                )
            except (OSError, ValueError) as error:
                print(
                    f"WARNING: Optional Wayland bridge unavailable: {error}. "
                    "Continuing with the X11 bridge.",
                    file=sys.stderr,
                )
            else:
                guest_environment.update(
                    STEAM_ASAHI_WAYLAND="1",
                    STEAM_ASAHI_WAYLAND_DISPLAY=WAYLAND_SOCKET_NAME,
                )
        arguments = [
            arguments[0],
            "--user-execute-pre",
            str(guest_session),
            *[
                *("-e", f"{name}={value}")
                for name, value in guest_environment.items()
            ],
            # Explicit per-backend environment arguments retain precedence
            *arguments[1:],
        ]
    for name in ("BASH_ENV", "ENV", *HOST_LOCALE_VARIABLES):
        environment.pop(name, None)
    environment.update(LANG="C.UTF-8", LC_ALL="C.UTF-8")
    sys.stdout.flush()
    sys.stderr.flush()
    if lock_descriptor is not None:
        # Python descriptors normally close at exec; muvm must retain the lock
        os.set_inheritable(lock_descriptor, True)
    # Match subprocess restore_signals when replacing Python with muvm
    for name in ("SIGPIPE", "SIGXFZ", "SIGXFSZ"):
        if hasattr(signal, name):
            signal.signal(getattr(signal, name), signal.SIG_DFL)
    os.execve(arguments[0], arguments, environment)


def warn_missing_audio_socket() -> None:
    socket = runtime_directory() / "pulse/native"
    if socket.is_socket():
        return
    print(f"WARNING: PulseAudio socket not found at {socket}.", file=sys.stderr)
    print(
        "Steam audio needs PipeWire Pulse or PulseAudio on the host.\n"
        "Enable one of them and restart Steam Asahi.",
        file=sys.stderr,
    )


def show_startup_splash(
    yad: str,
    cef_log: Path,
    hold_seconds: int,
    text: str,
) -> None:
    if (
        os.environ.get("STEAM_ASAHI_NO_SPLASH") == "1"
        or os.isatty(0)
        or os.isatty(1)
    ):
        return

    # Popen closes unrelated descriptors before returning, including the lock
    try:
        subprocess.Popen(
            [
                sys.executable,
                "-I",
                __file__,
                str(os.getpid()),
                str(time.time_ns()),
                yad,
                str(cef_log),
                str(hold_seconds),
                text,
            ],
            close_fds=True,
        )
    except OSError as error:
        print(f"WARNING: Startup dialog failed: {error}", file=sys.stderr)


def watch_startup_splash(
    launcher_pid: int,
    started: int,
    yad: str,
    cef_log: Path,
    hold_seconds: int,
    text: str,
) -> None:
    deadline = time.monotonic() + 180
    splash = None
    try:
        splash = subprocess.Popen(
            [
                yad,
                "--no-buttons",
                "--center",
                "--borders=16",
                "--title=Steam",
                "--window-icon=steam",
                "--skip-taskbar",
                "--timeout=180",
                f"--text={text}",
            ]
        )
        ready_deadline = None
        while splash.poll() is None and time.monotonic() < deadline:
            try:
                os.kill(launcher_pid, 0)
            except ProcessLookupError:
                break
            try:
                if (
                    ready_deadline is None
                    and cef_log.stat().st_mtime_ns > started
                ):
                    ready_deadline = time.monotonic() + hold_seconds
            except OSError:
                pass
            if (
                ready_deadline is not None
                and time.monotonic() >= ready_deadline
            ):
                break
            with suppress(subprocess.TimeoutExpired):
                splash.wait(timeout=1)
    except OSError as error:
        print(f"WARNING: Startup dialog failed: {error}", file=sys.stderr)
    finally:
        if splash is not None:
            splash.send_signal(signal.SIGTERM)
            try:
                splash.wait(timeout=2)
            except subprocess.TimeoutExpired:
                splash.kill()
                splash.wait()


if __name__ == "__main__":
    watch_startup_splash(
        int(sys.argv[1]),
        int(sys.argv[2]),
        sys.argv[3],
        Path(sys.argv[4]),
        int(sys.argv[5]),
        sys.argv[6],
    )
