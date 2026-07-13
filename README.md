<h1 align="center">Steam Asahi</h1>

<p align="center"><strong>Steam on NixOS Asahi Linux, powered by a 4K-page microVM.</strong></p>

<p align="center">
  <img alt="NixOS Asahi" src="https://img.shields.io/badge/NixOS-Asahi-5277C3?style=flat-square&amp;logo=nixos&amp;logoColor=white">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-aarch64-111111?style=flat-square&amp;logo=apple&amp;logoColor=white">
  <img alt="x86 FEX and ARM64 backends" src="https://img.shields.io/badge/backends-x86%2FFEX%20%7C%20ARM64-5C6BC0?style=flat-square">
  <img alt="Experimental project" src="https://img.shields.io/badge/status-experimental-F59E0B?style=flat-square">
</p>

![Steam running on NixOS Asahi Linux](https://github.com/user-attachments/assets/c8b4902b-3e69-43d7-8a21-29f91bb57f8f)

_Screenshot courtesy of EliSaado from `#asahi-alt` on OFTC IRC._

Steam expects 4K memory pages; Apple Silicon Linux hosts use 16K pages. This
flake handles that mismatch with [`muvm`](https://github.com/AsahiLinux/muvm)
and connects the guest to the accelerated Asahi GPU stack.

## What you get

- **One-command Steam** instead of a hand-built guest userspace.
- **Two backends:** the regular x86 client through FEX, or Valve's experimental
  native ARM64 client.
- **NixOS integration** for graphics, controllers, KVM access, memory limits,
  backend environment variables, and optional Steam service ports.
- **Shared Steam data** when switching backends, without duplicating games.

> [!WARNING]
> **This is experimental and was primarily written by an LLM. Review the code
> and use it at your own risk.**

## Install

Try it from a checkout:

```console
$ nix develop
$ steam-asahi
```

Or add the NixOS module to your flake:

```nix
{
  inputs.steam-asahi = {
    url = "github:sm-idk/steam-asahi";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, steam-asahi, ... }: {
    nixosConfigurations."«hostname»" = nixpkgs.lib.nixosSystem {
      modules = [
        steam-asahi.nixosModules.default
        {
          nixpkgs.hostPlatform = "aarch64-linux";

          programs.steam-asahi = {
            enable = true;
            backend = "x86-fex";
            memoryMiB = 6144; # optional; useful on an 8 GiB machine
            vramMiB = 4096;   # optional reported GPU heap size
          };

          # muvm is rootless, but needs access to /dev/kvm.
          users.users."«username»".extraGroups = [ "kvm" ];

          nixpkgs.config.allowUnfree = true;
        }
      ];
    };
  };
}
```

Rebuild, then open **Steam Asahi** or run `steam-asahi`.

Do not also enable `programs.steam` or `hardware.graphics.enable32Bit`; the
module reports both as configuration conflicts. Audio requires PipeWire Pulse
or PulseAudio. When WirePlumber is enabled, the module also installs muvm's
upstream access policy for native PipeWire portal clients.

| Module option                            | Purpose                                                              |
| ---------------------------------------- | -------------------------------------------------------------------- |
| `backend`                                | `"x86-fex"` (default) or `"arm64"`                                   |
| `memoryMiB`                              | Optional guest memory ceiling                                        |
| `vramMiB`                                | Optional video-memory heap size reported inside the guest            |
| `extraEnv`                               | Variables merged with the backend defaults; use `null` to remove one |
| `remotePlay.openFirewall`                | Open and forward ports for Steam Remote Play                         |
| `dedicatedServer.openFirewall`           | Open and forward Source Dedicated Server ports                       |
| `localNetworkGameTransfers.openFirewall` | Open and forward local game-transfer ports                           |

The three firewall options configure both the NixOS host firewall and
`muvm`/passt guest-to-host port publication. They are disabled by default.

## Backends

|                 | x86/FEX               | Native ARM64 beta                              |
| --------------- | --------------------- | ---------------------------------------------- |
| Steam client    | Standard x86 client   | Valve public beta                              |
| Recommended?    | **Yes**               | Testing only                                   |
| Windows games   | Standard Proton route | ARM Proton 11 route                            |
| Linux x86 games | FEX                   | Use FEX separately or select the Windows build |

Both run inside `muvm` because both clients need a 4K-page environment.

The ARM64 login screen may get stuck at **Waiting for network**. Log in once
with x86/FEX, then copy that login into isolated test state:

```console
$ nix develop
$ steam-asahi-arm64-test --import-login
```

For Windows games on ARM64, install **Proton 11.0 (ARM64)** (AppID `4628740`)
and **Steam Linux Runtime 4.0 - Arm64** (AppID `4185400`). The launcher then
registers the compatibility tool automatically.

> [!NOTE]
> Both backends use `~/.local/share/Steam`. Back it up before testing the ARM64
> beta; the isolated test command stores its copy under
> `~/.local/share/steam-asahi-arm64-test-home`.

## First launch

The x86 backend downloads a roughly 1.3 GB Fedora 43 FEX rootfs. Inside the
microVM it creates a temporary FHS layout and setuid `fusermount` wrappers.
Steam state and the downloaded rootfs remain in your user data.

You need NixOS on Apple Silicon, `/dev/kvm` access, working host graphics, and a
PulseAudio-compatible socket. Steam, Proton, and FEX are memory-heavy; use
`memoryMiB` and swap/zswap on lower-memory machines. `vramMiB` changes the
Asahi driver's reported heap size without reserving that memory up front.

## Diagnostics

```console
$ muvm --interactive -- bash -c 'getconf PAGESIZE'  # 4096
$ steam-asahi --fex 'uname -m'                      # x86_64
$ steam-asahi --fex 'vulkaninfo --summary'          # Apple GPU
```

Set `STEAM_ASAHI_NO_SPLASH=1` to disable the startup dialog.

## Development

```console
$ nix fmt
$ nix flake check -L
$ ./pkgs/steam-arm64-client/update.py  # refresh the Valve public-beta pin
```

The flake checks package builds and layouts, the updater fixture, NixOS module
evaluation, launcher behavior, ShellCheck/style policy, and a booted NixOS VM.
Run or debug that VM test directly on the current host architecture with:

```console
$ system=$(nix eval --impure --raw --expr builtins.currentSystem)
$ nix build ".#nixosTests.$system.steam-asahi-module" -L
$ nix run ".#nixosTests.$system.steam-asahi-module.driverInteractive"
```

The x86_64 VM uses test doubles for the architecture-specific payloads while
exercising the enabled module's system integration. On aarch64-linux, the VM is
a native aarch64 NixOS test. The separate module-evaluation check always
verifies that a real x86_64 configuration is rejected.

Shell sources follow the
[Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html):
Bash launchers use strict options, arrays for argv, quoted expansions, local
variables, `main`, two-space indentation, and an 80-column limit. The two Proton
entry points remain POSIX `sh` because they execute inside Valve's constrained
runtime. `nix flake check` runs ShellCheck plus the whitespace and line-length
policy.

Packages use nixpkgs' `writeShellApplication` with declared `runtimeInputs` and
`inheritPath = false`. Any new external command must therefore be added to its
launcher closure (or injected as an absolute store path), instead of leaking in
from the developer's host `PATH`.

## Thanks

Huge thanks to [4evy](https://github.com/4evy), who has done much of the heavy
lifting on this project. They introduced the shell launcher, NixOS module,
and desktop integration, then helped carry the current overhaul across both
backends, the module API, test coverage, and ARM Proton support.

Thanks also to [ooonea's fork](https://codeberg.org/ooonea/steam-asahi) for
reviving the project and validating many of the fixes now included here. The
underlying `muvm`, `libkrun`, and Asahi graphics fixes are upstream in nixpkgs.
