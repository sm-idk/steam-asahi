"""Validate Nix's JSON at the boundary before preparing launcher state"""

from pathlib import Path
from typing import Annotated, Literal, TypedDict, cast

import msgspec

from common import LauncherError

type Argument = Annotated[str, msgspec.Meta(pattern=r"^[^\x00]*\Z")]
type NonemptyArgument = Annotated[
    str, msgspec.Meta(min_length=1, pattern=r"^[^\x00]*\Z")
]
type EnvironmentName = Annotated[
    str, msgspec.Meta(pattern=r"^[A-Za-z_][A-Za-z0-9_]*\Z")
]


class LauncherConfiguration(TypedDict):
    MUVM: NonemptyArgument
    INIT_SCRIPT: NonemptyArgument
    YAD: NonemptyArgument
    CLIENT_BOOTSTRAP: NonemptyArgument
    CLIENT_UPDATE_CHANNEL: NonemptyArgument
    CPU_ARGS: list[Argument]
    MEMORY_ARGS: list[Argument]
    VRAM_ARGS: list[Argument]
    NETWORK_ARGS: list[Argument]


class Arm64Configuration(LauncherConfiguration):
    BACKEND: Literal["arm64"]
    COMPATIBILITY_TOOL_DIRECTORY: NonemptyArgument
    COMPATIBILITY_TOOL_VDF: NonemptyArgument
    CUSTOM_STEAM_HOME_DIR: Argument
    DEFAULT_STEAM_HOME_DIR: NonemptyArgument
    DISPLAY_NAME: NonemptyArgument
    GUEST_LAUNCHER: NonemptyArgument
    HOST_LIBRARIES: NonemptyArgument
    PROTON_DIRECTORY: NonemptyArgument
    PROTON_CONFIGURATOR: NonemptyArgument
    PROTON_RUNNER: NonemptyArgument
    PROTON_TOOL_NAME: NonemptyArgument
    PROTON_WRAPPER: NonemptyArgument
    RUNTIME_APP_ID: NonemptyArgument
    RUNTIME_DIRECTORY: NonemptyArgument
    TOOL_MANIFEST: NonemptyArgument


class FexConfiguration(LauncherConfiguration):
    BACKEND: Literal["x86-fex"]
    EXTRA_ENVIRONMENT: dict[EnvironmentName, Argument]
    FEX_BASH: NonemptyArgument
    FEX_DIAGNOSTIC_SCRIPT: NonemptyArgument
    FEX_ROOTFS_FETCHER: NonemptyArgument
    FEX_STEAM_SCRIPT: NonemptyArgument
    MUVM_HOST_MOUNT: NonemptyArgument
    MUVM_PATH: NonemptyArgument


type Configuration = Arm64Configuration | FexConfiguration

BACKEND_SCHEMAS = frozendict(
    {"arm64": Arm64Configuration, "x86-fex": FexConfiguration}
)


def parse_configuration(value: object) -> Configuration:
    if not isinstance(value, dict):
        raise LauncherError("launcher configuration must be a JSON object")
    value = cast(dict[str, object], value)
    backend = value.get("BACKEND")
    if not isinstance(backend, str) or backend not in BACKEND_SCHEMAS:
        raise LauncherError(f"unsupported launcher BACKEND: {backend!r}")

    try:
        msgspec.convert(value, type=BACKEND_SCHEMAS[backend], strict=True)
    except msgspec.ValidationError as error:
        raise LauncherError(str(error)) from error
    # Retain unknown keys too: the original configuration identifies the VM
    return cast(Configuration, value)


def load_configuration(path: Path) -> Configuration:
    try:
        value = msgspec.json.decode(path.read_bytes())
    except msgspec.DecodeError as error:
        raise LauncherError(
            f"invalid launcher configuration: {error}"
        ) from error
    return parse_configuration(value)
