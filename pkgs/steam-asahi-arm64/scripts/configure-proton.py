#!/usr/bin/env python3
"""Set one Steam application to use the managed ARM64 Proton tool."""

from __future__ import annotations

import argparse
import os
from collections.abc import MutableMapping
from pathlib import Path
import shutil
import tempfile

import vdf


class ConfigurationError(RuntimeError):
    """Steam's configuration cannot be updated safely."""


def parse_app_id(value: str) -> str:
    if (
        not value.isascii()
        or not value.isdecimal()
        or value.startswith("0")
    ):
        raise argparse.ArgumentTypeError("APPID must be a positive decimal integer")
    return value


def child_mapping(
    parent: MutableMapping[str, object], key: str
) -> MutableMapping[str, object]:
    value = parent.setdefault(key, {})
    if not isinstance(value, MutableMapping):
        raise ConfigurationError(f'expected VDF object at key "{key}"')
    return value


def update_config(config_path: Path, app_id: str, tool_name: str) -> bool:
    if not config_path.is_file():
        raise ConfigurationError(
            f"Steam configuration does not exist: {config_path}. "
            "Start and close Steam once before forcing Proton."
        )

    try:
        with config_path.open(encoding="utf-8") as config_file:
            config = vdf.load(config_file)
    except (OSError, SyntaxError, UnicodeError) as error:
        raise ConfigurationError(
            f"unable to read Steam configuration {config_path}: {error}"
        ) from error
    if not isinstance(config, MutableMapping):
        raise ConfigurationError(
            f"expected a VDF object at the root of {config_path}"
        )

    current = config
    for key in ("InstallConfigStore", "Software", "Valve", "Steam"):
        current = child_mapping(current, key)
    mappings = child_mapping(current, "CompatToolMapping")

    requested = {
        "name": tool_name,
        "config": "",
        "priority": "250",
    }
    if mappings.get(app_id) == requested:
        return False
    mappings[app_id] = requested

    backup_path = config_path.with_name(
        f"{config_path.name}.steam-asahi-backup"
    )
    try:
        if not backup_path.exists():
            shutil.copy2(config_path, backup_path)

        temporary_fd, temporary_name = tempfile.mkstemp(
            dir=config_path.parent,
            prefix=f".{config_path.name}.",
        )
        temporary_path = Path(temporary_name)
        try:
            with os.fdopen(temporary_fd, "w", encoding="utf-8") as config_file:
                vdf.dump(config, config_file, pretty=True)
            temporary_path.chmod(config_path.stat().st_mode & 0o777)
            temporary_path.replace(config_path)
        except BaseException:
            temporary_path.unlink(missing_ok=True)
            raise
    except OSError as error:
        raise ConfigurationError(
            f"unable to update Steam configuration {config_path}: {error}"
        ) from error

    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("config_path", type=Path)
    parser.add_argument("app_id", type=parse_app_id)
    parser.add_argument("tool_name")
    arguments = parser.parse_args()

    try:
        changed = update_config(
            arguments.config_path, arguments.app_id, arguments.tool_name
        )
    except ConfigurationError as error:
        parser.error(str(error))

    if changed:
        print(
            f"Configured Steam AppID {arguments.app_id} to use "
            f"{arguments.tool_name}."
        )
    else:
        print(
            f"Steam AppID {arguments.app_id} already uses "
            f"{arguments.tool_name}."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
