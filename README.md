# Steam Asahi

Steam Asahi runs Steam on NixOS Asahi Linux. [4evy](https://github.com/4evy)
did much of the work on the current implementation. She introduced the
launcher, NixOS module, and desktop integration.

Valve's binaries need 4K memory pages, but Linux on Apple Silicon uses 16K
pages. The launcher uses a 4K-page
[`muvm`](https://github.com/AsahiLinux/muvm) microVM with accelerated Asahi
graphics. The default backend runs x86 Steam through FEX. The native ARM64
Steam beta is available for testing.

> [!WARNING]
> This project is experimental and was developed with substantial LLM
> assistance.

![Steam running on NixOS Asahi Linux](https://github.com/user-attachments/assets/c8b4902b-3e69-43d7-8a21-29f91bb57f8f)

_Screenshot by EliSaado from `#asahi-alt` on OFTC IRC._

## Requirements

- NixOS on Apple Silicon (`aarch64-linux`) with working Asahi graphics
- Access to `/dev/kvm`, normally through membership in the `kvm` group
- PipeWire with PulseAudio compatibility, or PulseAudio

> [!IMPORTANT]
> Disable `programs.steam` and `hardware.graphics.enable32Bit`. Both conflict
> with this module, which provides its own client and uses 64-bit host graphics.

## Install and launch

Add the flake input and import the module in your existing NixOS configuration:

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

In `configuration.nix`, allow the unfree packages, enable Steam Asahi, and add
your user to the `kvm` group:

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

Replace `«hostname»` and `«username»`, then rebuild:

```console
sudo nixos-rebuild switch --flake .#«hostname»
```

Log out and back in if you added yourself to `kvm`. Then open **Steam Asahi**
from the application launcher, or run `steam-asahi` in your host shell.
Don't run it as root.

The first x86 launch downloads a Fedora 44 FEX root filesystem (about 1.3 GB).
The module sets up host graphics and controller rules, but you'll need to
configure your audio server separately.

## Configuration

All settings below go under `programs.steam-asahi`:

| Option               | Default          | Purpose                                                                 |
| -------------------- | ---------------- | ----------------------------------------------------------------------- |
| `backend`            | `"x86-fex"`      | Select x86/FEX or experimental `"arm64"`                                |
| `cpuList`            | `null`           | Host CPU IDs, one guest vCPU per ID. Defaults to performance cores      |
| `memoryMiB`          | `null`           | VM memory ceiling. Defaults to 80% of host RAM, allocated on demand     |
| `vramMiB`            | `null`           | Reported GPU heap size. Defaults to half of host RAM, not a reservation |
| `extraEnv`           | Backend defaults | Override guest environment variables. Use `null` to remove a variable   |
| `nativeWayland`      | `true`           | Expose a guest Wayland display through Waypipe                          |
| `customSteamHomeDir` | `null`           | Override the isolated ARM64 home directory                              |

On an 8 GiB machine, for example, leave some memory for the host:

```nix
programs.steam-asahi.memoryMiB = 6144;
```

Swap or zswap can help if you're short on memory. For CPU tuning, check host
IDs with `lscpu -e=CPU,MAXMHZ` before setting `cpuList`. Adding efficiency cores
can help threaded workloads but hurt frame pacing, so compare results per game.

To enable Remote Play, Source Dedicated Server, or local game transfers, set
the matching option to `true`: `remotePlay.openFirewall`,
`dedicatedServer.openFirewall`, or `localNetworkGameTransfers.openFirewall`.
Each opens the host firewall and forwards the guest ports through muvm/passt.
All three are off by default.

The [module options](nixos/modules/steam.nix) describe the remaining settings
and their defaults.

### Per-game Wayland

Steam uses XWayland. To let a game use the guest Wayland display, set its Steam
launch options to:

```text
steam-asahi-game --wayland -- %command%
```

Use `--xwayland` instead to select XWayland. This only selects the display.
It doesn't enable Proton's Wine Wayland driver or guarantee that a game works
with Wayland.

## Experimental ARM64 backend

Set `programs.steam-asahi.backend = "arm64"` and rebuild to use Valve's native
ARM64 public beta. It still needs the 4K-page microVM.

This backend keeps its state in `$XDG_DATA_HOME/steam-asahi-arm64-home`
(normally `~/.local/share/steam-asahi-arm64-home`). **Don't add your x86 Steam
library to this client.** The two backends must not share mutable `compatdata`.
Use `customSteamHomeDir` if you want a different ARM64 home.

If you're already logged in to x86 Steam, close Steam and copy the login state:

```console
steam-asahi --import-login
```

For Windows games, install **Proton 11.0 (ARM64)** and **Steam Linux Runtime
4.0 - Arm64** in Steam. The launcher registers **Proton 11.0 (ARM64) [Steam
Asahi]**, a wrapper that supplies the NixOS libraries and compatibility paths
games need. Choose this wrapper rather than Valve's unwrapped Proton entry.

Games with x86-only Linux builds need the Windows build through this wrapper.
Close Steam, then run this with the game's numeric AppID to set the
compatibility tool and launch the game:

```console
steam-asahi --force-proton APPID
```

Before changing a compatibility mapping, the launcher makes a one-time backup
of `config.vdf` as `config.vdf.steam-asahi-backup`.

## Troubleshooting

- **Waiting for network at login:** a known Steam client regression can affect
  both backends. See [project issue #6] and [Valve issue #13493] for status and
  the tested temporary login procedure.
- **No audio:** check that
  `${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native` exists, then restart
  Steam Asahi.
- **ARM64 game exits immediately:** check whether it needs to be forced to
  Proton. Look for the wrapper's `steam-asahi-proton.log` in its directory
  under `Steam/compatibilitytools.d`.
- **Desktop integration problems:** run `steam-asahi --desktop-diagnostics`
  for host and guest reports, or add `--host-only` to check only the host.
- **Inspect the guest:** on x86/FEX, run
  `steam-asahi --fex 'vulkaninfo --summary'`. On ARM64, run
  `steam-asahi --guest uname -m` or `steam-asahi --guest getconf PAGESIZE`.
- **Disable the startup dialog:** set `STEAM_ASAHI_NO_SPLASH=1` when launching.

## Development

On an Apple Silicon host that meets the requirements, run `nix develop` from a
checkout to try the launchers without installing the module. The shell provides
`steam-asahi` (x86/FEX), `steam-asahi-arm64`, and `steam-asahi-arm64-test`.
The test launcher uses a separate ARM64 home. The shell doesn't apply the
module's system configuration.

Format and check the code with:

```console
nix fmt
nix flake check -L
```

To evaluate both `aarch64-linux` and `x86_64-linux` outputs without building:

```console
nix flake check --all-systems --no-build -L
```

Checks cover package layouts, module evaluation, launcher behavior, ShellCheck,
and source formatting. They don't boot a VM or test games or desktop
integration. Those still need testing on Apple Silicon.

[project issue #6]: https://github.com/sm-idk/steam-asahi/issues/6
[Valve issue #13493]: https://github.com/ValveSoftware/steam-for-linux/issues/13493
