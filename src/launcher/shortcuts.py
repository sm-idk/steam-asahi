"""Keep Steam-generated game shortcuts usable from the host desktop"""

import os
import re
import select
import stat
import sys
from collections.abc import Callable
from contextlib import suppress
from pathlib import Path
from uuid import uuid4

from boltons.fileutils import atomic_save

from common import install_managed_file

MANAGED = "X-SteamAsahi-Managed=true"
STEAM_GAME_EXEC = re.compile(r"Exec=steam (steam://rungameid/[0-9]+)")
REFRESH_INTERVAL = 5


def desktop_lines(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="surrogateescape")
    return text.removesuffix("\n").split("\n")


def entry_section(lines: list[str]) -> range:
    try:
        start = lines.index("[Desktop Entry]") + 1
    except ValueError:
        return range(0)
    for index in range(start, len(lines)):
        if lines[index].startswith("["):
            return range(start, index)
    return range(start, len(lines))


def is_managed(path: Path) -> bool:
    lines = desktop_lines(path)
    return any(lines[index] == MANAGED for index in entry_section(lines))


def rewrite_shortcut(
    source: Path, destination: Path, launcher: str, mode: int
) -> bool:
    lines = desktop_lines(source)
    section = entry_section(lines)
    commands = [i for i in section if lines[i].startswith("Exec=")]
    if len(commands) != 1:
        return False
    index = commands[0]
    if not (match := STEAM_GAME_EXEC.fullmatch(lines[index])):
        return False
    # Never export guest desktop actions as commands the host can run
    if source != destination and section.stop != len(lines):
        return False
    lines[index] = f"Exec={launcher} {match[1]}"
    for i in section:
        if lines[i] == "TryExec=steam":
            lines[i] = f"TryExec={launcher}"
    if not any(lines[i] == MANAGED for i in section):
        lines.insert(section.stop, MANAGED)
    with atomic_save(
        destination, file_perms=mode, part_file=f".{uuid4().hex}"
    ) as output:
        output.write(
            ("\n".join(lines) + "\n").encode("utf-8", "surrogateescape")
        )
    return True


def repair_fex_shortcuts(home: Path, data_home: Path, launcher: str) -> None:
    desktop = Path(os.environ.get("XDG_DESKTOP_DIR", ""))
    if not desktop.is_absolute():
        desktop = home / "Desktop"
    for directory in (desktop, data_home / "applications"):
        for path in directory.glob("*.desktop"):
            with suppress(FileNotFoundError):
                mode = path.lstat().st_mode
                if stat.S_ISREG(mode):
                    rewrite_shortcut(path, path, launcher, stat.S_IMODE(mode))


def sync_arm64_shortcuts(home: Path, data_home: Path, launcher: str) -> None:
    guest_data = home / ".local/share"
    icons = guest_data / "icons"
    # Install artwork first so menu indexers don't see a missing icon
    for source in icons.glob("*/*/apps/steam_icon_*"):
        with suppress(FileNotFoundError):
            info = source.lstat()
            if not stat.S_ISREG(info.st_mode):
                continue
            target = data_home / "icons" / source.relative_to(icons)
            if (
                target.is_file()
                and target.stat().st_mtime_ns >= info.st_mtime_ns
            ):
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            install_managed_file(source, target, 0o644)

    applications = data_home / "applications"
    prefix = f"{launcher}-"
    present = set()
    for directory in (guest_data / "applications", home / "Desktop"):
        for source in directory.glob("*.desktop"):
            if source.name in present:
                continue
            with suppress(FileNotFoundError):
                info = source.lstat()
                if not stat.S_ISREG(info.st_mode):
                    continue
                target = applications / f"{prefix}{source.name}"
                mode = stat.S_IMODE(info.st_mode)
                if target.exists(follow_symlinks=False):
                    current = target.lstat()
                    if not stat.S_ISREG(current.st_mode) or not is_managed(
                        target
                    ):
                        continue
                    if (
                        current.st_mtime_ns >= info.st_mtime_ns
                        and stat.S_IMODE(current.st_mode) == mode
                    ):
                        present.add(source.name)
                        continue
                applications.mkdir(parents=True, exist_ok=True)
                if rewrite_shortcut(source, target, launcher, mode):
                    present.add(source.name)
    for target in applications.glob(f"{prefix}*.desktop"):
        if target.name.removeprefix(prefix) in present:
            continue
        with suppress(FileNotFoundError):
            if target.is_file(follow_symlinks=False) and is_managed(target):
                target.unlink()


def start_shortcut_watcher(
    refresh: Callable[[], None], lock_descriptor: int | None
) -> None:
    def refresh_entries() -> None:
        with suppress(OSError):
            refresh()

    refresh_entries()
    # The pidfd follows the launcher across exec into muvm without PID reuse
    try:
        parent = os.pidfd_open(os.getpid())
        try:
            child = os.fork()
        except BaseException:
            os.close(parent)
            raise
    except OSError as error:
        print(
            f"WARNING: Cannot watch Steam shortcuts: {error}", file=sys.stderr
        )
        return
    if child:
        os.close(parent)
        return
    try:
        # Only the launcher/muvm may keep the Steam lock across its lifetime
        if lock_descriptor is not None:
            os.close(lock_descriptor)
        os.setsid()
        with open(os.devnull, "r+b", buffering=0) as null:
            for descriptor in (0, 1, 2):
                os.dup2(null.fileno(), descriptor)
        # Guest writes don't deliver inotify events through virtiofs
        while not select.select([parent], [], [], REFRESH_INTERVAL)[0]:
            refresh_entries()
        refresh_entries()
    finally:
        os._exit(0)
