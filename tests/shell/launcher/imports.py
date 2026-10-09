#!/usr/bin/env python3.14
# /// script
# requires-python = "==3.14.*"
# dependencies = []
# ///

"""Check that importing the launchers preserves the environment"""

import os
import sys

sys.path.insert(0, sys.argv[1])
original_environment = os.environ.copy()
import arm64
import common
import fex

assert os.environ == original_environment, (
    "importing launchers changed HOME/XDG"
)
assert callable(arm64.Arm64Launcher.import_login_state)
assert callable(arm64.Arm64Launcher.acquire_lock)
assert callable(common.install_managed_file)
assert callable(common.write_managed_value)
assert callable(fex.FexLauncher.ensure_fex_rootfs)
