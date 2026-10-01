# /// script
# requires-python = "==3.14.*"
# dependencies = []
# ///

"""Validate Nix's JSON at the boundary before preparing launcher state"""

from typing import (
    Literal,
    TypedDict,
    cast,
    get_args,
    get_origin,
    get_type_hints,
)

from common import LauncherError


class LauncherConfiguration(TypedDict):
    MUVM: str
    INIT_SCRIPT: str
    YAD: str
    CPU_ARGS: list[str]
    MEMORY_ARGS: list[str]
    VRAM_ARGS: list[str]
    NETWORK_ARGS: list[str]


class Arm64Configuration(LauncherConfiguration):
    BACKEND: Literal["arm64"]
    CLIENT_BOOTSTRAP: str
    CLIENT_UPDATE_CHANNEL: str
    COMPATIBILITY_TOOL_DIRECTORY: str
    COMPATIBILITY_TOOL_VDF: str
    CUSTOM_STEAM_HOME_DIR: str
    DEFAULT_STEAM_HOME_DIR: str
    DISPLAY_NAME: str
    GUEST_LAUNCHER: str
    HOST_LIBRARIES: str
    PROTON_DIRECTORY: str
    PROTON_CONFIGURATOR: str
    PROTON_RUNNER: str
    PROTON_TOOL_NAME: str
    PROTON_WRAPPER: str
    RUNTIME_APP_ID: str
    RUNTIME_DIRECTORY: str
    TOOL_MANIFEST: str


class FexConfiguration(LauncherConfiguration):
    BACKEND: Literal["x86-fex"]
    EXTRA_ENVIRONMENT_ARGS: list[str]
    FEX_BASH: str
    FEX_DIAGNOSTIC_SCRIPT: str
    FEX_ROOTFS_FETCHER: str
    FEX_STEAM_SCRIPT: str
    MUVM_HOST_MOUNT: str
    MUVM_PATH: str
    STEAM_BOOTSTRAP: str


type Configuration = Arm64Configuration | FexConfiguration


def parse_configuration(value: object) -> Configuration:
    if not isinstance(value, dict):
        raise LauncherError("launcher configuration must be a JSON object")
    value = cast(dict[str, object], value)
    schemas = {"arm64": Arm64Configuration, "x86-fex": FexConfiguration}
    backend = value.get("BACKEND")
    if not isinstance(backend, str) or backend not in schemas:
        raise LauncherError(f"unsupported launcher BACKEND: {backend!r}")

    # The TypedDict is also the runtime schema, so required fields stay in sync
    for name, annotation in get_type_hints(schemas[backend]).items():
        if name not in value:
            raise LauncherError(f"missing launcher configuration field: {name}")
        field = value[name]
        if annotation is str:
            valid = isinstance(field, str)
        elif annotation == list[str]:
            valid = isinstance(field, list) and all(
                isinstance(item, str) for item in field
            )
        elif get_origin(annotation) is Literal:
            valid = field in get_args(annotation)
        else:
            raise TypeError(
                f"unsupported configuration annotation: {annotation}"
            )
        if not valid:
            raise LauncherError(
                f"invalid launcher configuration field {name}: "
                f"expected {annotation}"
            )
    return cast(Configuration, value)
