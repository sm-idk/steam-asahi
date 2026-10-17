"""Resolve host and isolated guest directories from the XDG defaults"""

import os
from collections.abc import Mapping
from pathlib import Path

XDG_HOME_DEFAULTS = frozendict(
    {
        "XDG_CACHE_HOME": ".cache",
        "XDG_CONFIG_HOME": ".config",
        "XDG_DATA_HOME": ".local/share",
        "XDG_STATE_HOME": ".local/state",
    }
)


def xdg_home(
    name: str, *, environment: Mapping[str, str] | None = None
) -> Path:
    environment = os.environ if environment is None else environment
    if value := environment.get(name):
        path = Path(value)
        if path.is_absolute():
            return path
    # The XDG specification requires ignoring relative directory overrides
    home = environment.get("HOME")
    return (Path(home) if home else Path.home()) / XDG_HOME_DEFAULTS[name]


def runtime_directory(environment: Mapping[str, str] | None = None) -> Path:
    environment = os.environ if environment is None else environment
    return Path(
        environment.get("XDG_RUNTIME_DIR") or f"/run/user/{os.geteuid()}"
    )


def isolated_home_environment(home: Path) -> dict[str, str]:
    return {"HOME": str(home)} | {
        name: str(home / suffix) for name, suffix in XDG_HOME_DEFAULTS.items()
    }
