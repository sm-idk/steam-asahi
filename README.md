# Steam Asahi

<!-- rumdl-disable MD033 -->

<p align="center">
  <strong>Steam on NixOS Asahi Linux, powered by a 4K-page microVM</strong>
</p>

<p align="center">
  <img alt="NixOS Asahi" src="https://img.shields.io/badge/NixOS-Asahi-5277C3?style=flat-square&amp;logo=nixos&amp;logoColor=white">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-aarch64-111111?style=flat-square&amp;logo=apple&amp;logoColor=white">
  <img alt="x86 FEX and ARM64 backends" src="https://img.shields.io/badge/backends-x86%2FFEX%20%7C%20ARM64-5C6BC0?style=flat-square">
  <img alt="Experimental project" src="https://img.shields.io/badge/status-experimental-F59E0B?style=flat-square">
</p>

<!-- rumdl-enable MD033 -->

> [!WARNING]
> This project is experimental and was developed with substantial LLM
> assistance.

![Steam running on NixOS Asahi Linux](https://github.com/user-attachments/assets/c8b4902b-3e69-43d7-8a21-29f91bb57f8f)

_Screenshot courtesy of EliSaado from `#asahi-alt` on OFTC IRC._

Steam requires **4K memory pages**, while Linux on Apple Silicon uses 16K
pages. Steam Asahi bridges that gap with a 4K-page
[`muvm`](https://github.com/AsahiLinux/muvm) microVM with accelerated Asahi
graphics. It runs the standard x86 Steam client through FEX by default, with
an experimental native ARM64 backend available for testing.

## Requirements

- **System:** NixOS on Apple Silicon
- **Virtualization:** access to `/dev/kvm`
- **Graphics:** a working Asahi graphics stack
- **Audio:** PipeWire with PulseAudio compatibility, or PulseAudio

## Quick start

### 1. Add the module

Add the flake input and module alongside your existing NixOS configuration:

```nix
{
  inputs.steam-asahi = {
    url = "github:sm-idk/steam-asahi";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, steam-asahi, ... }: {
    nixosConfigurations."«hostname»" = nixpkgs.lib.nixosSystem {
      modules = [
        ./configuration.nix
        steam-asahi.nixosModules.default
      ];
    };
  };
}
```

Let `hardware-configuration.nix` or NixOS Facter set `nixpkgs.hostPlatform` for
the machine; do not repeat it in the flake.

Then enable Steam Asahi in `configuration.nix`:

```nix
{
  nixpkgs.config.allowUnfreePackages = [
    "steam-asahi"
    "steam-asahi-arm64"
    "steam-arm64-client"
    "steam-unwrapped"
  ];

  programs.steam-asahi.enable = true;

  users.users."«username»".extraGroups = [ "kvm" ];
}
```

### 2. Rebuild

Replace `«hostname»` and `«username»`, then apply the configuration:

```console
sudo nixos-rebuild switch --flake .#«hostname»
```

### 3. Launch

Open **Steam Asahi** from the application launcher, or run:

```console
steam-asahi
```

Run `steam-asahi` directly from the host shell. The first x86 launch downloads
an approximately 1.3 GiB Fedora 44 FEX root filesystem.

> [!IMPORTANT]
> Do not enable `programs.steam` or `hardware.graphics.enable32Bit`. The
> module replaces that setup and reports either option as a conflict.

If the host already meets the graphics, KVM, and audio requirements, try the
project from a checkout before adding the module:

```console
nix develop
steam-asahi
```

The development shell provides the launchers but does not apply the module's
NixOS configuration.

## Configuration

The x86/FEX backend is the recommended default. Common optional settings are:

```nix
programs.steam-asahi = {
  backend = "x86-fex"; # or the experimental "arm64" backend
  memoryMiB = 6144;    # useful on an 8 GiB machine
  vramMiB = 4096;      # GPU heap size reported inside the guest
};
```

Steam, Proton, and FEX are memory-heavy. Consider swap or zswap on machines
with less RAM.

| Option                                       | Purpose                                                |
| -------------------------------------------- | ------------------------------------------------------ |
| `backend`                                    | Select `"x86-fex"` (default) or experimental `"arm64"` |
| `customSteamHomeDir`                         | Set the isolated ARM64 home directory                  |
| `memoryMiB`                                  | Limit the microVM's memory in MiB                      |
| `vramMiB`                                    | Set the GPU heap size reported inside the guest        |
| `extraEnv`                                   | Add or replace guest environment variables             |
| `remotePlay.openFirewall`                    | Enable Remote Play ports                               |
| `dedicatedServer.openFirewall`               | Enable Source server ports                             |
| `localNetworkGameTransfers.openFirewall`     | Enable local transfer ports                            |

The firewall options both open the NixOS host firewall and publish the same
ports from the `muvm` guest through passt. They are disabled by default. Values
in `extraEnv` merge with the selected backend's defaults; set a defaulted
variable to `null` to remove it.

## Backends

|                 | x86/FEX             | Native ARM64 beta                        |
| --------------- | ------------------- | ---------------------------------------- |
| Steam client    | Standard x86 client | Valve public beta                        |
| Recommended     | Yes                 | Testing only                             |
| Windows games   | Standard Proton     | Proton 11.0 (ARM64)                      |
| x86 Linux games | FEX                 | Use the Windows build through ARM Proton |

### Native ARM64 backend

The experimental ARM64 beta uses separate Steam state under
`$XDG_DATA_HOME/steam-asahi-arm64-home` (normally
`~/.local/share/steam-asahi-arm64-home`). Do not add the x86 Steam library to
the ARM64 client because the backends must not share mutable `compatdata`.

If you already have an authenticated x86 installation, exit Steam, switch the
module backend to `"arm64"`, rebuild, and import a copy of the login state:

```console
steam-asahi --import-login
```

For Windows games, install **Proton 11.0 (ARM64)** and **Steam Linux Runtime
4.0 - Arm64**. Force games with x86-only Linux builds to use Proton so Steam
downloads their Windows build. Close Steam, then configure and launch the game
with its numeric AppID:

```console
steam-asahi --force-proton APPID
```

The launcher creates a one-time `config.vdf.steam-asahi-backup` before changing
the game's compatibility mapping.

## Troubleshooting

- **Waiting for network on a fresh login:** this is a current Steam client
  regression, not failed guest networking, and it can affect both backends.
  Follow [project issue #6] and [Valve issue #13493] for status and the tested
  temporary login procedure.
- **No audio:** verify that
  `${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native` exists, then restart
  Steam Asahi.
- **A game exits immediately on ARM64:** ignore `gameoverlayrenderer.so` preload
  warnings, then check whether the game needs to be forced to Proton. The
  compatibility tool writes details to `steam-asahi-proton.log` in its
  directory below `Steam/compatibilitytools.d`.
- **Inspect the guest:** run `steam-asahi --fex 'uname -m'` or
  `steam-asahi --fex 'vulkaninfo --summary'`.

Set `STEAM_ASAHI_NO_SPLASH=1` to disable the startup dialog.

## Development

Format and verify the current host with:

```console
nix fmt
nix flake check -L
```

Evaluate outputs for both supported check platforms without building them:

```console
nix flake check --all-systems --no-build -L
```

The checks cover package layouts, the ARM client updater fixture, NixOS module
evaluation, launch argument handling, ShellCheck and source policy, and a
booted NixOS VM. Run the VM test directly with:

```console
system=$(nix eval --impure --raw --expr builtins.currentSystem)
nix build ".#checks.$system.steam-asahi-nixos-vm" -L
```

## Thanks

Huge thanks to [4evy](https://github.com/4evy). She introduced the shell
launcher, NixOS module, and desktop integration and did much of the work on
the current implementation.

Thanks also to [ooonea's fork](https://codeberg.org/ooonea/steam-asahi) for
reviving the project and validating many of its fixes. The underlying `muvm`,
`libkrun`, and Asahi graphics fixes are upstream in nixpkgs.

[project issue #6]: https://github.com/sm-idk/steam-asahi/issues/6
[Valve issue #13493]: https://github.com/ValveSoftware/steam-for-linux/issues/13493
