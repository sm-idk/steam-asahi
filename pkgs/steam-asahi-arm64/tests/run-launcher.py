#!/usr/bin/env python3.14
# /// script
# requires-python = "==3.14.*"
# dependencies = []
# ///

"""Run the ARM64 launcher with the shell fixture configuration"""

import json
import os
from pathlib import Path
import sys

repository = Path(sys.argv[1])
keys = (
    "CLIENT_BOOTSTRAP",
    "CLIENT_UPDATE_CHANNEL",
    "COMPATIBILITY_TOOL_DIRECTORY",
    "COMPATIBILITY_TOOL_VDF",
    "CUSTOM_STEAM_HOME_DIR",
    "DEFAULT_STEAM_HOME_DIR",
    "DISPLAY_NAME",
    "GUEST_LAUNCHER",
    "HOST_LIBRARIES",
    "INIT_SCRIPT",
    "MUVM",
    "PROTON_DIRECTORY",
    "PROTON_CONFIGURATOR",
    "PROTON_RUNNER",
    "PROTON_TOOL_NAME",
    "PROTON_WRAPPER",
    "RUNTIME_APP_ID",
    "RUNTIME_DIRECTORY",
    "TOOL_MANIFEST",
    "YAD",
)
configuration = {key: os.environ[key] for key in keys}
configuration.update(
    BACKEND="arm64", CPU_ARGS=[], MEMORY_ARGS=[], NETWORK_ARGS=[], VRAM_ARGS=[]
)
config_path = Path(os.environ["TEST_MUVM_OUTPUT"]).with_suffix(".json")
config_path.write_text(json.dumps(configuration))
launcher = repository / "pkgs/scripts/launcher/main.py"
os.execv(
    sys.executable,
    [
        sys.executable,
        "-I",
        "-B",
        str(launcher),
        str(config_path),
        *sys.argv[2:],
    ],
)
