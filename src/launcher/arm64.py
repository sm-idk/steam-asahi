# /// script
# requires-python = "==3.14.*"
# dependencies = ["boltons", "msgspec"]
# ///

"""Install isolated ARM64 Steam state and launch it through muvm"""

from __future__ import annotations

import fcntl
import os
import sys
from pathlib import Path
from typing import NoReturn

from common import (
    PRESSURE_VESSEL_FILESYSTEMS_RO,
    STEAM_CLIENT_ARGS,
    LauncherError,
    copy_bootstrap,
    exec_guest,
    executable,
    install_managed_file,
    muvm_arguments,
    replace_symlink,
    run,
    show_startup_splash,
    warn_missing_audio_socket,
    write_managed_value,
    xdg_home,
)
from configuration import Arm64Configuration


class Arm64Launcher:
    def __init__(self, configuration: Arm64Configuration) -> None:
        self.config = configuration
        self.source_home = Path.home()
        self.source_config_home = xdg_home("XDG_CONFIG_HOME", ".config")
        self.source_data_home = xdg_home("XDG_DATA_HOME", ".local/share")
        requested_home = Path(
            configuration["CUSTOM_STEAM_HOME_DIR"]
            or configuration["DEFAULT_STEAM_HOME_DIR"]
        )
        self.home = (
            requested_home
            if requested_home.is_absolute()
            else self.source_data_home / requested_home
        )
        self.steam = self.home / ".local/share/Steam"
        self.client = self.steam / "steamrtarm64"
        self.compatibility = (
            self.steam
            / "compatibilitytools.d"
            / configuration["COMPATIBILITY_TOOL_DIRECTORY"]
        )
        self.proton = (
            self.steam / "steamapps/common" / configuration["PROTON_DIRECTORY"]
        )
        self.runtime = (
            self.steam / "steamapps/common" / configuration["RUNTIME_DIRECTORY"]
        )
        self.lock_descriptor: int | None = None

    def initialize_environment(self) -> None:
        os.environ["HOME"] = str(self.home)
        for name, suffix in {
            "XDG_CACHE_HOME": ".cache",
            "XDG_CONFIG_HOME": ".config",
            "XDG_DATA_HOME": ".local/share",
            "XDG_STATE_HOME": ".local/state",
        }.items():
            os.environ[name] = str(self.home / suffix)

    def acquire_lock(self, arguments: list[str]) -> None:
        # Guest Steam PIDs cannot be checked against the host's /proc
        self.steam.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(
            self.steam / ".steam-asahi.lock", os.O_RDWR | os.O_CREAT, 0o666
        )
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            os.close(descriptor)
            if arguments[:1] == ["--force-proton"]:
                message = (
                    "Close Steam before changing a compatibility-tool mapping"
                )
            elif arguments[:1] == ["--import-login"]:
                message = "Close Steam before importing login state"
            else:
                # muvm forwards this command into its existing guest, where
                # Steam can find its PID and handle URLs or reopen the window
                print("Forwarding command to the running ARM64 Steam client...")
                self.run_guest(
                    ["--forward", str(self.client / "steam"), *arguments],
                    interactive=False,
                    reuse_only=True,
                )
            raise LauncherError(message) from error
        except BaseException:
            os.close(descriptor)
            raise
        self.lock_descriptor = descriptor

    def run_guest(
        self,
        arguments: list[str],
        *,
        interactive: bool = True,
        reuse_only: bool = False,
    ) -> NoReturn:
        config = self.config
        exec_guest(
            muvm_arguments(
                config,
                {
                    "PRESSURE_VESSEL_FILESYSTEMS_RO": PRESSURE_VESSEL_FILESYSTEMS_RO,
                    "STEAM_ASAHI_GUEST_HOME": str(self.home),
                    "STEAM_ASAHI_GUEST_UID": str(os.geteuid()),
                },
                interactive=interactive,
            )
            + [
                "--",
                config["GUEST_LAUNCHER"],
                *arguments,
            ],
            self.lock_descriptor,
            configuration=config,
            reuse_only=reuse_only,
        )

    def sync_pulse_cookie(self) -> None:
        source = self.source_config_home / "pulse/cookie"
        target = self.home / ".config/pulse/cookie"
        if not source.is_file():
            source = self.source_home / ".pulse-cookie"
        if not source.is_file() or source == target:
            return
        target.parent.mkdir(parents=True, exist_ok=True)
        # Reinstall matching contents too, repairing a permissive cookie mode
        install_managed_file(source, target, 0o600)

    def import_login_state(self) -> None:
        source = self.source_data_home / "Steam"
        paths = ("local.vdf", "config/loginusers.vdf", "config/config.vdf")
        if source == self.steam:
            raise LauncherError(
                "the source and isolated Steam directories are identical"
            )
        if any(not (source / path).is_file() for path in paths):
            raise LauncherError(f"incomplete x86 Steam login under {source}")
        (self.steam / "config").mkdir(parents=True, exist_ok=True)
        (self.home / ".steam").mkdir(parents=True, exist_ok=True)
        for path in paths:
            install_managed_file(source / path, self.steam / path, 0o600)
        registry = self.source_home / ".steam/registry.vdf"
        if registry.is_file():
            install_managed_file(
                registry, self.home / ".steam/registry.vdf", 0o600
            )
        print(
            f"Imported the x86 Steam login into isolated state at {self.home}."
        )

    def install_client_bootstrap(self) -> None:
        if executable(self.client / "steam"):
            return
        print("Installing the pinned ARM64 Steam beta bootstrap...")
        copy_bootstrap(self.config["CLIENT_BOOTSTRAP"], self.client)

    def configure_steam_state(self) -> None:
        beta = self.steam / "package/beta"
        beta.parent.mkdir(parents=True, exist_ok=True)
        (self.home / ".steam").mkdir(parents=True, exist_ok=True)
        channel = self.config["CLIENT_UPDATE_CHANNEL"]
        if not beta.is_file() or beta.read_text().rstrip("\n") != channel:
            write_managed_value(beta, channel)
        for name, target in {
            "root": self.steam,
            "sdkarm64": self.steam / "linuxarm64",
            "steam": self.steam,
        }.items():
            destination = self.home / ".steam" / name
            if not destination.exists() and not destination.is_symlink():
                destination.symlink_to(target)

    def proton_payloads_installed(self) -> bool:
        return executable(self.proton / "proton") and executable(
            self.runtime / "_v2-entry-point"
        )

    def install_proton_integration(self) -> None:
        config = self.config
        if not self.proton_payloads_installed():
            if executable(self.proton / "proton"):
                print(
                    f"{config['DISPLAY_NAME']} is installed, but Steam Linux "
                    f"Runtime 4.0 - Arm64 (AppID {config['RUNTIME_APP_ID']}) "
                    "is missing.",
                    file=sys.stderr,
                )
            return

        self.compatibility.mkdir(parents=True, exist_ok=True)
        for name, (source, mode) in {
            "compatibilitytool.vdf": (config["COMPATIBILITY_TOOL_VDF"], 0o644),
            "run-proton": (config["PROTON_RUNNER"], 0o755),
            "steam-asahi-proton": (config["PROTON_WRAPPER"], 0o755),
            "toolmanifest.vdf": (config["TOOL_MANIFEST"], 0o644),
        }.items():
            install_managed_file(source, self.compatibility / name, mode)
        for name, target in {
            "host-libs": config["HOST_LIBRARIES"],
            "proton": self.proton,
            "runtime": self.runtime,
        }.items():
            replace_symlink(target, self.compatibility / name)
        (self.steam / "compatibilitytools.d/steam-asahi-arm64.vdf").unlink(
            missing_ok=True
        )
        log = self.compatibility / "steam-asahi-proton.log"
        try:
            if log.lstat().st_size > 1024 * 1024:
                log.replace(log.with_suffix(".log.old"))
        except OSError:
            # Optional log rotation must not prevent Steam from launching
            pass

    def main(self, arguments: list[str]) -> None:
        self.initialize_environment()
        import_login = arguments[:1] == ["--import-login"]
        if import_login:
            arguments = arguments[1:]
        if arguments[:1] == ["--guest"]:
            if import_login:
                raise LauncherError(
                    "--import-login cannot be combined with --guest"
                )
            if len(arguments) == 1:
                raise LauncherError(
                    "usage: steam-asahi --guest command [arguments...]"
                )
            self.run_guest(arguments[1:])

        print(f"Using isolated ARM64 Steam home: {self.home}")
        self.acquire_lock(
            ["--import-login", *arguments] if import_login else arguments
        )
        app_id = None
        if arguments[:1] == ["--force-proton"]:
            if len(arguments) == 1:
                raise LauncherError("usage: steam-asahi --force-proton APPID")
            app_id = arguments[1]
            if (
                not app_id.isascii()
                or not app_id.isdecimal()
                or app_id.startswith("0")
            ):
                raise LauncherError("APPID must be a positive decimal integer")
            arguments = arguments[2:]

        warn_missing_audio_socket()
        self.sync_pulse_cookie()
        self.install_client_bootstrap()
        self.configure_steam_state()
        if import_login:
            self.import_login_state()
        self.install_proton_integration()
        if app_id is not None:
            if not self.proton_payloads_installed() or not executable(
                self.compatibility / "steam-asahi-proton"
            ):
                raise LauncherError(
                    f"{self.config['DISPLAY_NAME']} and Steam Linux Runtime "
                    "4.0 - Arm64 must be installed"
                )
            run(
                self.config["PROTON_CONFIGURATOR"],
                self.steam / "config/config.vdf",
                app_id,
                self.config["PROTON_TOOL_NAME"],
            )
            arguments = [f"steam://run/{app_id}", *arguments]
        show_startup_splash(
            self.config["YAD"],
            self.steam / "logs/cef_log.txt",
            5,
            "Starting native ARM64 Steam (4K-page microVM)...",
        )
        print("Launching native ARM64 Steam via muvm...")
        self.run_guest(
            [
                "--steam",
                str(self.client / "steam"),
                *STEAM_CLIENT_ARGS,
                *arguments,
            ]
        )
