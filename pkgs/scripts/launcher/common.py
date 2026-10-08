# /// script
# requires-python = "==3.14.*"
# dependencies = ["boltons"]
# ///

"""Host file and process helpers shared by both Steam launchers"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from collections.abc import Mapping
from pathlib import Path
from typing import TYPE_CHECKING, NoReturn
from uuid import uuid4

from boltons.fileutils import atomic_save

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
    return os.access(path, os.X_OK)


def xdg_home(name: str, suffix: str) -> Path:
    return Path(os.environ.get(name) or str(Path.home() / suffix))


def run(*arguments: str | Path) -> None:
    subprocess.run(arguments, check=True)


def copy_bootstrap(source: str, destination: Path) -> None:
    # Preserve archive metadata and merge partial installs using coreutils
    destination.mkdir(parents=True, exist_ok=True)
    run("cp", "--archive", "--no-target-directory", "--", source, destination)
    run("chmod", "-RP", "u+rwX", "--", destination)


def install_managed_file(
    source: str | Path, destination: Path, mode: int
) -> None:
    with (
        Path(source).open("rb") as source_file,
        atomic_save(
            str(destination), file_perms=mode, part_file=f".{uuid4().hex}"
        ) as destination_file,
    ):
        shutil.copyfileobj(source_file, destination_file)


def write_managed_value(destination: Path, value: str) -> None:
    with atomic_save(
        str(destination), file_perms=0o600, part_file=f".{uuid4().hex}"
    ) as destination_file:
        destination_file.write(f"{value}\n".encode("utf-8"))


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
        *(
            argument
            for name, value in environment.items()
            for argument in ("-e", f"{name}={value}")
        ),
    ]


def exec_guest(
    arguments: list[str],
    lock_descriptor: int | None = None,
    *,
    configuration: LauncherConfiguration,
    reuse_only: bool = False,
) -> NoReturn:
    environment = os.environ.copy()
    environment.pop("MUVM_RUNTIME_DIR", None)
    default_runtime = Path(f"/run/user/{os.geteuid()}")
    if not environment.get("XDG_RUNTIME_DIR") and default_runtime.is_dir():
        environment["XDG_RUNTIME_DIR"] = str(default_runtime)
    if runtime := environment.get("XDG_RUNTIME_DIR"):
        # muvm reuses a VM without rerunning init or applying boot options
        # Include the home because ARM64 init rewrites the guest passwd entry
        identity = json.dumps(
            [configuration, str(Path.home())], sort_keys=True
        ).encode()
        instance = hashlib.sha256(identity).hexdigest()[:16]
        directory = Path(runtime) / "steam-asahi" / instance
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        environment["MUVM_RUNTIME_DIR"] = str(directory)
    if reuse_only:
        # A held Steam lock can belong to a VM from another configuration
        # Refuse to boot a second VM against that same mutable Steam home
        running = False
        if runtime_directory := environment.get("MUVM_RUNTIME_DIR"):
            try:
                with (Path(runtime_directory) / "muvm.lock").open() as lock:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        running = True
            except FileNotFoundError:
                pass
        if not running:
            raise LauncherError(
                "Steam Asahi is already running with another launcher "
                "configuration; close Steam before using this launcher"
            )
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
    runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.geteuid()}"
    socket = Path(runtime) / "pulse/native"
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
        while time.monotonic() < deadline:
            try:
                os.kill(launcher_pid, 0)
            except ProcessLookupError:
                break
            try:
                if cef_log.stat().st_mtime_ns > started:
                    time.sleep(hold_seconds)
                    break
            except OSError:
                pass
            time.sleep(1)
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
