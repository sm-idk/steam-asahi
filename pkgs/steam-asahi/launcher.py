#!/usr/bin/env python3
"""
steam-asahi: NixOS launcher for Steam on Apple Silicon via muvm + FEX-Emu.

Based on Fedora Asahi's shim.py by Alyssa Rosenzweig.
Adapted for NixOS with declarative Steam bootstrap packaging.

SPDX-License-Identifier: MIT
"""

import glob
import json
import os
import subprocess
import sys
import tarfile

from xdg import BaseDirectory

LAUNCHER_NAME = "steam-asahi"

# These are the files we need from the Steam bootstrap tarball.
MANIFEST = [
    "steam-launcher/steam_subscriber_agreement.txt",
    "steam-launcher/bin_steam.sh",
    "steam-launcher/bootstraplinux_ubuntu12_32.tar.xz",
]

# Nix store paths (substituted at build time)
MUVM = "@muvm@"
INIT_SCRIPT = "@initScript@"
FEX_ROOTFS_FETCHER = "@fexRootFSFetcher@"
STEAM_BOOTSTRAP = "@steamBootstrap@"

# Steam launch args
STEAM_ARGS = ["-cef-force-occlusion"]

# Steam runtime libraries that conflict with FEX emulation.
# These bundled libraries cause crashes (especially CEF/steamwebhelper).
# Removing them forces Steam to use the rootfs versions instead.
# See: https://wiki.fex-emu.com/index.php/Steam
STEAM_RUNTIME_LIBS_TO_REMOVE = {
    # 32-bit runtime libraries that conflict with FEX
    "ubuntu12_32/steam-runtime/usr/lib/i386-linux-gnu": [
        "libstdc++*",
        "libxcb*",
        "libgcc_s*",
    ],
    # 64-bit runtime libraries that cause CEF crashes
    "ubuntu12_32/steam-runtime/lib/x86_64-linux-gnu": [
        "libz.so*",
        "libfreetype.so.6*",
        "libfontconfig.so.1*",
        "libdbus-1.so*",
    ],
}


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def is_fex_rootfs_configured():
    """Check if FEX has a rootfs configured."""
    fex_emu_dir = os.path.expanduser("~/.fex-emu")
    rootfs_dir = os.path.join(fex_emu_dir, "RootFS")

    if os.path.isdir(rootfs_dir):
        for f in os.listdir(rootfs_dir):
            full = os.path.join(rootfs_dir, f)
            if f.endswith((".ero", ".sqsh", ".img")) or os.path.isdir(full):
                return True

    config_path = os.path.join(fex_emu_dir, "Config.json")
    if os.path.isfile(config_path):
        try:
            with open(config_path) as f:
                config = json.load(f)
            if config.get("Config", {}).get("RootFS", ""):
                return True
        except (json.JSONDecodeError, KeyError):
            pass

    return False


def setup_fex_rootfs():
    """Download FEX rootfs using FEXRootFSFetcher."""
    print("FEX rootfs not found. Downloading Fedora 43 rootfs...")
    print("This is a one-time setup (~1.3GB download).")
    print()

    result = subprocess.run([
        FEX_ROOTFS_FETCHER,
        "--assume-yes",
        "--distro-name=Fedora",
        "--distro-version=43",
        "--distro-list-first",
        "--as-is",
    ])

    if result.returncode != 0:
        print("Automatic download failed. Trying interactive mode...")
        subprocess.run([FEX_ROOTFS_FETCHER])


def ensure_steam_bootstrap(data_dir):
    """Extract Steam bootstrap from the Nix store into the data directory."""
    marker = os.path.join(data_dir, "bootstrap-installed")
    bootstrap_script = os.path.join(data_dir, "steam-launcher", "bin_steam.sh")

    if os.path.isfile(marker) and os.path.isfile(bootstrap_script):
        return

    print("Setting up Steam bootstrap...")
    os.makedirs(data_dir, exist_ok=True)

    # Clean old install
    install_dir = os.path.join(data_dir, "steam-launcher")
    if os.path.isdir(install_dir):
        for item in MANIFEST:
            path = os.path.join(data_dir, item)
            if os.path.exists(path):
                os.unlink(path)

    # Extract from Nix store copy
    with tarfile.open(STEAM_BOOTSTRAP, mode="r:gz") as tar:
        members = [m for m in tar.getmembers() if m.name in MANIFEST]
        tar.extractall(path=data_dir, members=members, filter="data")

    open(marker, "w").write("ok")
    print("Steam bootstrap ready.")


def cleanup_steam_runtime_libs():
    """Remove bundled Steam runtime libraries that conflict with FEX.

    Steam bundles old versions of system libraries for compatibility.
    Under FEX emulation, these cause crashes (especially CEF/Chromium).
    Removing them forces Steam to use the FEX rootfs versions.
    """
    steam_dir = os.path.expanduser("~/.local/share/Steam")
    if not os.path.isdir(steam_dir):
        return

    removed = 0
    for rel_dir, patterns in STEAM_RUNTIME_LIBS_TO_REMOVE.items():
        lib_dir = os.path.join(steam_dir, rel_dir)
        if not os.path.isdir(lib_dir):
            continue
        for pattern in patterns:
            for lib in glob.glob(os.path.join(lib_dir, pattern)):
                try:
                    os.unlink(lib)
                    removed += 1
                except OSError:
                    pass

    if removed > 0:
        print(f"Removed {removed} conflicting Steam runtime libraries.")


def run_steam(data_dir):
    """Launch Steam via muvm + FEXBash.

    Matches Fedora Asahi's approach: minimal flags, no --interactive.
    muvm 0.5.x fixed CEF issues at the VM level so workarounds aren't needed.
    The only addition is --execute-pre for NixOS FHS path fixups.
    """
    steam_args = " ".join(STEAM_ARGS + sys.argv[1:])

    cmd = [
        MUVM,
        "--execute-pre", INIT_SCRIPT,
        "--interactive",
        # PressureVessel (bwrap) creates a container for games. By default it
        # doesn't mount /nix, so FEX can't find its thunks (GPU library
        # forwarding) inside the container. Without thunks, games fall back to
        # llvmpipe software rendering.
        # /run/opengl-driver has the native ARM64 Mesa/Vulkan drivers.
        # PressureVessel needs /nix for FEX thunks (GPU forwarding) and
        # /run/opengl-driver for native ARM64 Mesa/Vulkan drivers.
        "-e", "PRESSURE_VESSEL_FILESYSTEMS_RO=/nix:/run/opengl-driver",
        "--",
        "FEXBash",
        "-c",
        f"{data_dir}/steam-launcher/bin_steam.sh {steam_args}",
    ]

    print("Launching Steam via muvm + FEX...")
    proc = subprocess.Popen(cmd)
    ret = proc.wait()

    if ret != 0:
        print(f"muvm exited with code {ret}")
    sys.exit(ret)


def main():
    if os.geteuid() == 0:
        die(f"Do not run `{sys.argv[0]}` as root")

    # Step 1: Ensure FEX rootfs
    if not is_fex_rootfs_configured():
        setup_fex_rootfs()
    if not is_fex_rootfs_configured():
        die("FEX rootfs not configured. Run FEXRootFSFetcher manually.")

    # Step 2: Ensure PulseAudio config for muvm vsock audio
    # SHM doesn't work through virtio. Create client.conf in $HOME so it's
    # visible inside PressureVessel containers (unlike /run/pulse.conf which
    # gets lost when PV creates its own /run tmpfs).
    pulse_dir = os.path.expanduser("~/.config/pulse")
    pulse_conf = os.path.join(pulse_dir, "client.conf")
    if not os.path.isfile(pulse_conf):
        os.makedirs(pulse_dir, exist_ok=True)
        with open(pulse_conf, "w") as f:
            f.write("enable-shm = no\n")
        print("Created PulseAudio config (SHM disabled for muvm vsock).")

    # Step 3: Ensure Steam bootstrap
    data_dir = BaseDirectory.save_data_path(LAUNCHER_NAME)
    ensure_steam_bootstrap(data_dir)

    # Step 3: Launch Steam
    run_steam(data_dir)


if __name__ == "__main__":
    main()
