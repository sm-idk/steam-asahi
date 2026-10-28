"""Check guest resource capabilities before selecting descriptor transport"""

import os
import stat
import subprocess
from pathlib import Path

READY_MESSAGE = b"PORTAL_PIPEWIRE_V1\n"
CHECK_TIMEOUT = 5


def check_guest_resources(helper: Path) -> bool:
    from . import HOST_IDENTITY, HOST_IDENTITY_XATTR

    if (
        not helper.is_absolute()
        or not helper.is_file()
        or not os.access(helper, os.X_OK)
    ):
        raise ValueError(
            "the packaged PipeWire attachment helper is unavailable"
        )
    identity = os.getxattr(helper, HOST_IDENTITY_XATTR)
    if len(identity) != HOST_IDENTITY.size:
        raise ValueError("the host filesystem identity query is incompatible")
    magic, _, _, kind, reserved = HOST_IDENTITY.unpack(identity)
    if magic != b"SAFI0001" or kind != stat.S_IFREG or reserved != 0:
        raise ValueError("the host filesystem identity query is incompatible")
    try:
        result = subprocess.run(
            [helper, "--check"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=CHECK_TIMEOUT,
        )
    except subprocess.TimeoutExpired as error:
        raise TimeoutError("the PipeWire capability query timed out") from error
    if result.returncode != 0:
        detail = result.stderr.decode(errors="replace").strip()[-1024:]
        raise ValueError(
            "the guest GPU cannot attach registered PipeWire remotes"
            + (f": {detail}" if detail else "")
        )
    if result.stdout != READY_MESSAGE:
        raise ValueError("the PipeWire attachment helper is incompatible")
    return True
