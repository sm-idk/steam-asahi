#!/usr/bin/env python3.15
# /// script
# requires-python = "==3.15.*"
# dependencies = ["boltons==25.0.0", "vdf==3.4"]
# ///

"""Set one Steam application to use the managed ARM64 Proton tool"""

from __future__ import annotations

import argparse
import re
from pathlib import Path
from uuid import uuid4

import vdf
from boltons.fileutils import atomic_save

type VdfObject = vdf.VDFDict

COMPAT_TOOL_MAPPING_PATH = (
    "InstallConfigStore",
    "Software",
    "Valve",
    "Steam",
    "CompatToolMapping",
)
PROTON_MAPPING_DEFAULTS = frozendict({"config": "", "priority": "250"})


class Arguments(argparse.Namespace):
    config_path: Path
    app_id: str
    tool_name: str


class ConfigurationError(RuntimeError):
    """Steam's configuration cannot be updated safely"""


def parse_app_id(value: str) -> str:
    if re.fullmatch(r"[1-9][0-9]*", value) is None:
        raise argparse.ArgumentTypeError(
            "APPID must be a positive decimal integer"
        )
    return value


def child_mapping(parent: VdfObject, key: str) -> VdfObject:
    # Steam matches keys without case sensitivity; VDFDict preserves spelling
    matches = [
        value
        for name, value in parent.items()
        if name.isascii() and name.casefold() == key.casefold()
    ]
    if len(matches) > 1:
        raise ConfigurationError(
            f'ambiguous duplicate VDF object at key "{key}"'
        )
    if matches:
        value = matches[0]
    else:
        value = vdf.VDFDict()
        parent[key] = value
    if not isinstance(value, vdf.VDFDict):
        raise ConfigurationError(f'expected VDF object at key "{key}"')
    return value


def update_config(config_path: Path, app_id: str, tool_name: str) -> bool:
    if not config_path.is_file():
        raise ConfigurationError(
            f"Steam configuration does not exist: {config_path}. "
            "Start and close Steam once before forcing Proton."
        )

    try:
        original = config_path.read_bytes()
        # Preserve duplicate entries outside the mapping being changed
        config = vdf.loads(
            original.decode("utf-8"),
            mapper=vdf.VDFDict,
            merge_duplicate_keys=False,
        )
    except (OSError, SyntaxError, UnicodeError, RecursionError) as error:
        raise ConfigurationError(
            f"unable to read Steam configuration {config_path}: {error}"
        ) from error

    # VDF leaves are strings; validate objects as we traverse the requested path
    mappings = config
    for key in COMPAT_TOOL_MAPPING_PATH:
        mappings = child_mapping(mappings, key)

    requested = {"name": tool_name, **PROTON_MAPPING_DEFAULTS}
    existing = mappings.get_all_for(app_id)
    if len(existing) == 1 and isinstance(
        current_mapping := existing[0], vdf.VDFDict
    ):
        # VDFDict equality includes order; Steam treats these as named fields
        if (
            len(current_mapping) == len(requested)
            and {
                name.casefold(): value
                for name, value in current_mapping.items()
            }
            == requested
        ):
            return False
    if app_id in mappings:
        mappings.remove_all_for(app_id)
    mappings[app_id] = vdf.VDFDict(requested)

    backup_path = config_path.with_name(
        f"{config_path.name}.steam-asahi-backup"
    )
    try:
        try:
            with atomic_save(
                backup_path,
                overwrite=False,
                file_perms=0o600,
                part_file=f".{uuid4().hex}",
            ) as backup:
                backup.write(original)
        except FileExistsError:
            pass

        with atomic_save(
            config_path, text_mode=True, part_file=f".{uuid4().hex}"
        ) as config_file:
            config_file.reconfigure(encoding="utf-8")
            vdf.dump(config, config_file, pretty=True)
            if config_path.read_bytes() != original:
                raise ConfigurationError(
                    "Steam configuration changed during the update; "
                    "close Steam and try again"
                )
    except (OSError, UnicodeError, RecursionError) as error:
        raise ConfigurationError(
            f"unable to update Steam configuration {config_path}: {error}"
        ) from error

    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("config_path", type=Path)
    parser.add_argument("app_id", type=parse_app_id)
    parser.add_argument("tool_name")
    arguments = parser.parse_args(namespace=Arguments())

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
