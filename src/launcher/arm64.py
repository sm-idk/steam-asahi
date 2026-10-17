"""Install isolated ARM64 Steam state and launch it through muvm"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path
from typing import NoReturn

from common import (
    STEAM_CLIENT_ARGS,
    LauncherError,
    acquire_steam_lock,
    configure_steam_state,
    exec_guest,
    executable,
    install_managed_file,
    install_client_bootstrap,
    muvm_arguments,
    replace_symlink,
    run,
    show_startup_splash,
    steam_directory,
    steam_guest_environment,
    warn_missing_audio_socket,
)
from configuration import Arm64Configuration
from environment import isolated_home_environment, xdg_home


# The guest repairs Valve's helper and FFmpeg library before launch. Bootstrap
# verification would restore their original bytes and request another restart
# This flag leaves update checks enabled while preserving the local repairs
ARM64_CLIENT_ARGS = (*STEAM_CLIENT_ARGS, "-noverifyfiles")
LOGIN_STATE_FILES = ("local.vdf", "config/loginusers.vdf", "config/config.vdf")
PROTON_MANAGED_FILES = (
    ("compatibilitytool.vdf", "COMPATIBILITY_TOOL_VDF", 0o644),
    ("run-proton", "PROTON_RUNNER", 0o755),
    ("steam-asahi-proton", "PROTON_WRAPPER", 0o755),
    ("toolmanifest.vdf", "TOOL_MANIFEST", 0o644),
)
LOCKED_COMMAND_ERRORS = frozendict(
    {
        "--force-proton": (
            "Close Steam before changing a compatibility-tool mapping"
        ),
        "--import-login": "Close Steam before importing login state",
    }
)
MAX_PROTON_LOG_BYTES = 1024 * 1024


class Arm64Launcher:
    def __init__(self, configuration: Arm64Configuration) -> None:
        self.config = configuration
        self.host_environment = os.environ.copy()
        self.source_home = Path.home()
        self.source_config_home = xdg_home("XDG_CONFIG_HOME")
        self.source_data_home = xdg_home("XDG_DATA_HOME")
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
        os.environ.update(isolated_home_environment(self.home))

    def acquire_lock(self, arguments: list[str]) -> None:
        # Guest Steam PIDs cannot be checked against the host's /proc
        try:
            self.lock_descriptor = acquire_steam_lock(self.steam, 0o666)
        except BlockingIOError as error:
            command = arguments[0] if arguments else ""
            message = LOCKED_COMMAND_ERRORS.get(command)
            if message is None:
                # muvm forwards this command into its existing guest, where
                # Steam can find its PID and handle URLs or reopen the window
                print("Forwarding command to the running ARM64 Steam client...")
                self.run_guest(
                    [
                        "--forward",
                        str(self.client / "steam"),
                        *ARM64_CLIENT_ARGS,
                        *arguments,
                    ],
                    interactive=False,
                    reuse_only=True,
                )
            raise LauncherError(message) from error

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
                steam_guest_environment()
                | {
                    "STEAM_ASAHI_GUEST_HOME": str(self.home),
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
            host_environment=self.host_environment,
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
        source = steam_directory(self.source_home, self.source_data_home)
        if source.resolve() == self.steam.resolve():
            raise LauncherError(
                "the source and isolated Steam directories are identical"
            )
        if any(not (source / path).is_file() for path in LOGIN_STATE_FILES):
            raise LauncherError(f"incomplete x86 Steam login under {source}")
        (self.steam / "config").mkdir(parents=True, exist_ok=True)
        (self.home / ".steam").mkdir(parents=True, exist_ok=True)
        for path in LOGIN_STATE_FILES:
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
        install_client_bootstrap(
            self.config["CLIENT_BOOTSTRAP"], self.client, "ARM64"
        )

    def configure_steam_state(self) -> None:
        configure_steam_state(
            self.home,
            self.steam,
            self.config["CLIENT_UPDATE_CHANNEL"],
            {
                "root": self.steam,
                "sdkarm64": self.steam / "linuxarm64",
                "steam": self.steam,
            },
        )

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
        for name, source_key, mode in PROTON_MANAGED_FILES:
            install_managed_file(
                config[source_key], self.compatibility / name, mode
            )
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
            if log.lstat().st_size > MAX_PROTON_LOG_BYTES:
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
            if re.fullmatch(r"[1-9][0-9]*", app_id) is None:
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
                *ARM64_CLIENT_ARGS,
                *arguments,
            ]
        )
