"""Prepare FEX and Steam state, then launch Steam through muvm and FEX"""

from __future__ import annotations

import os
import subprocess
from collections.abc import Mapping
from pathlib import Path

import msgspec

from common import (
    PRESSURE_VESSEL_FILESYSTEMS_RO,
    STEAM_CLIENT_ARGS,
    LauncherError,
    copy_bootstrap,
    exec_guest,
    executable,
    muvm_arguments,
    show_startup_splash,
    steam_directory,
    warn_missing_audio_socket,
    write_managed_value,
    xdg_home,
)
from configuration import FexConfiguration

FEX_BASH_COMMAND = 'exec /bin/bash "$@"'


class FexLauncher:
    def __init__(self, configuration: FexConfiguration) -> None:
        self.config = configuration
        self.home = Path.home()
        self.steam = steam_directory(
            self.home, xdg_home("XDG_DATA_HOME", ".local/share")
        )
        self.client = self.steam / "steamrt64"

    def ensure_fex_rootfs(
        self, extra_environment: Mapping[str, str] | None = None
    ) -> None:
        environment = os.environ | (extra_environment or {})
        if environment.get("FEX_ROOTFS"):
            return
        data_home = xdg_home(
            "XDG_DATA_HOME", ".local/share", environment=environment
        )
        config_home = xdg_home(
            "XDG_CONFIG_HOME", ".config", environment=environment
        )
        environment.update(
            XDG_DATA_HOME=str(data_home), XDG_CONFIG_HOME=str(config_home)
        )
        home = Path(environment.get("HOME") or self.home)
        legacy = home / ".fex-emu"
        if legacy.is_dir():
            data = legacy
            config_path = legacy / "Config.json"
        else:
            data = Path(
                environment.get("FEX_APP_DATA_LOCATION")
                or str(data_home / "fex-emu")
            )
            config_path = config_home / "fex-emu/Config.json"

        if config_override := environment.get("FEX_APP_CONFIG_LOCATION"):
            config_directory = Path(config_override)
            if not config_directory.is_absolute():
                # FEX resolves relative config overrides beside its executable
                config_directory = (
                    Path(self.config["FEX_ROOTFS_FETCHER"]).parent
                    / config_directory
                )
            config_path = config_directory / "Config.json"

        rootfs = data / "RootFS"
        if rootfs.is_dir():
            for path in rootfs.iterdir():
                # Bash's original glob ignored hidden entries
                if not path.name.startswith(".") and (
                    path.info.is_dir()
                    or (
                        path.info.is_file()
                        and path.suffix in (".ero", ".img", ".sqsh")
                    )
                ):
                    return
        try:
            configuration = msgspec.json.decode(config_path.read_bytes())
        except OSError, msgspec.DecodeError:
            configuration = {}
        # FEX stores options in Config; accept the legacy top-level form too
        if isinstance(configuration, dict):
            options = configuration.get("Config", configuration)
            if isinstance(options, dict):
                selected_rootfs = options.get("RootFS")
                if isinstance(selected_rootfs, str) and selected_rootfs:
                    return

        print(
            "FEX rootfs not found. Downloading Fedora 44 rootfs...\n"
            "This is a one-time setup (~1.3 GB download)."
        )
        try:
            subprocess.run(
                [
                    self.config["FEX_ROOTFS_FETCHER"],
                    "--assume-yes",
                    "--distro-name=Fedora",
                    "--distro-version=44",
                    "--distro-list-first",
                    "--as-is",
                ],
                env=environment,
                check=True,
            )
        except subprocess.CalledProcessError as error:
            raise LauncherError(
                "FEX rootfs download failed; run FEXRootFSFetcher manually."
            ) from error

    def muvm_arguments(
        self, extra_environment: Mapping[str, str] | None = None
    ) -> list[str]:
        config = self.config
        path = ":".join(
            [
                "/run/wrappers/bin",
                config["MUVM_PATH"],
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
            ]
        )
        environment = {
            "PATH": path,
            **{
                name: value
                for name, value in os.environ.items()
                if name.startswith("FEX_")
                or name in ("XDG_CACHE_HOME", "XDG_STATE_HOME")
            },
        }
        environment.update(extra_environment or {})
        host_environment = os.environ | environment
        for name, suffix in (
            ("XDG_DATA_HOME", ".local/share"),
            ("XDG_CONFIG_HOME", ".config"),
        ):
            environment[name] = str(
                xdg_home(name, suffix, environment=host_environment)
            )
        return muvm_arguments(config, environment, emulator="fex")

    def fex_arguments(self, script: str, arguments: list[str]) -> list[str]:
        # FEXBash interprets a command string; remaining argv stays intact
        return [
            "--",
            self.config["FEX_BASH"],
            FEX_BASH_COMMAND,
            "steam-asahi-fex",
            script,
            *arguments,
        ]

    def install_client_bootstrap(self) -> None:
        if executable(self.client / "steam"):
            return
        print("Installing the pinned x86_64 Steam beta bootstrap...")
        copy_bootstrap(self.config["CLIENT_BOOTSTRAP"], self.client)

    def configure_steam_state(self) -> None:
        beta = self.steam / "package/beta"
        beta.parent.mkdir(parents=True, exist_ok=True)
        channel = self.config["CLIENT_UPDATE_CHANNEL"]
        write_managed_value(beta, channel)
        # The client honors Valve's opt-out even when launched directly
        # Remove our obsolete opt-in marker from earlier launcher versions too
        for marker in (
            ".steam-disable-steamrt64-client",
            ".steam-enable-steamrt64-client",
        ):
            (self.steam / marker).unlink(missing_ok=True)
        directory = self.home / ".steam"
        directory.mkdir(parents=True, exist_ok=True)
        for name in ("root", "steam"):
            link = directory / name
            if not link.exists(follow_symlinks=False):
                link.symlink_to(self.steam)

    def main(self, arguments: list[str]) -> None:
        if Path(self.config["MUVM_HOST_MOUNT"]).is_dir():
            raise LauncherError(
                "Already inside a muvm guest. Exit FEXBash and run "
                "steam-asahi on the host."
            )
        diagnostic = arguments[:1] == ["--fex"]
        if diagnostic and len(arguments) != 2:
            raise LauncherError("usage: steam-asahi --fex '<command>'")
        steam_environment = self.config["EXTRA_ENVIRONMENT"]
        self.ensure_fex_rootfs(None if diagnostic else steam_environment)
        if diagnostic:
            exec_guest(
                self.muvm_arguments()
                + self.fex_arguments(
                    self.config["FEX_DIAGNOSTIC_SCRIPT"], arguments[1:]
                ),
                configuration=self.config,
            )

        warn_missing_audio_socket()
        show_startup_splash(
            self.config["YAD"],
            self.steam / "logs/cef_log.txt",
            10,
            "Starting Steam (microVM + FEX)...",
        )
        self.install_client_bootstrap()
        self.configure_steam_state()
        print("Launching 64-bit Steam beta via muvm + FEX...")
        exec_guest(
            self.muvm_arguments(
                {
                    "PRESSURE_VESSEL_FILESYSTEMS_RO": PRESSURE_VESSEL_FILESYSTEMS_RO,
                    "STEAM_ASAHI_GUEST_UID": str(os.geteuid()),
                    **steam_environment,
                }
            )
            + self.fex_arguments(
                self.config["FEX_STEAM_SCRIPT"],
                [
                    str(self.client / "steam"),
                    *STEAM_CLIENT_ARGS,
                    *arguments,
                ],
            ),
            configuration=self.config,
        )
