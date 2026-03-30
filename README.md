# steam-asahi

Nix flake to run Steam on NixOS Asahi Linux (Apple Silicon) via muvm + FEX-Emu.

## Warning

**This project was primarily written by an LLM (AI). Review the code yourself before running it. Use at your own risk.**

The launcher performs several potentially dangerous operations at runtime:

- **Bind-mounts over `/bin`, `/usr`, and `/etc`** inside the muvm guest to create an FHS-compatible environment for Steam
- **Sets suid root on `fusermount`** (copied to `/run/wrappers/bin/`) so FEX can mount its rootfs overlay
- **Downloads a ~1.3GB FEX rootfs** (Fedora 43) on first run via `FEXRootFSFetcher`
- **Extracts a Steam bootstrap tarball** into `~/.local/share/steam-asahi/`
- **Removes conflicting Steam runtime libraries** from `~/.local/share/Steam/` that conflict with FEX emulation
- **Writes PulseAudio config** to `~/.config/pulse/client.conf`

## Components

| Component | Version | Source |
|-----------|---------|--------|
| **libkrunfw** | 5.3.0 | [containers/libkrunfw](https://github.com/containers/libkrunfw) (kernel 6.12.76) |
| **libkrun** | 1.17.4 | [containers/libkrun](https://github.com/containers/libkrun) |
| **muvm** | 0.5.1 | [AsahiLinux/muvm](https://github.com/AsahiLinux/muvm) |
| **FEX-Emu** | 2603 | [FEX-Emu/FEX](https://github.com/FEX-Emu/FEX) taken directly from nixpkgs-unstable|
| **Steam bootstrap** | 1.0.0.81 | [repo.steampowered.com](https://repo.steampowered.com/steam/archive/stable/) |

All packages are built as overlays on top of nixpkgs-unstable.

## Usage

```sh
nix develop # And then use the components provided by the flake like the `steam-asahi` script
```

You can also use it as a module
  
```
{
  inputs = {
    steam-asahi.url = "github:sm-idk/steam-asahi";
  };

  outputs =
    { nixpkgs, steam-asahi, ... }:
    {
      nixosConfigurations."«hostname»" = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          steam-asahi.nixosModules.default
          {
            programs.steam-asahi.enable = true;
          }
        ];
      };
    };
}
```
