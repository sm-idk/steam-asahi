# steam-asahi

Nix flake to run Steam on NixOS Asahi Linux (Apple Silicon) via muvm + FEX-Emu.

<img width="3444" height="1967" alt="Image" src="https://github.com/user-attachments/assets/c8b4902b-3e69-43d7-8a21-29f91bb57f8f" />

> Picture generously provided by EliSaado from the #asahi-alt oftc IRC

## Warning

> [!WARNING]
>  **This project was primarily written by an LLM (AI). Review the code yourself before running it. Use at your own risk.**

The launcher performs several potentially dangerous operations at runtime:

- **Bind-mounts over `/bin`, `/usr`, and `/etc`** inside the muvm guest to create an FHS-compatible environment for Steam
- **Sets suid root on `fusermount` and `fusermount3`** (copied to `/run/wrappers/bin/`) so FEX can mount its rootfs overlay
- **Downloads a ~1.3GB FEX rootfs** (Fedora 43) on first run via `FEXRootFSFetcher`
- **Installs Steam bootstrap files** into `~/.local/share/steam-asahi/`

## Components

| Component | Version | Source |
|-----------|---------|--------|
| **libkrunfw** | 5.3.0 (kernel 6.12.76) | [containers/libkrunfw](https://github.com/containers/libkrunfw) PR upstreamed at [#505042](https://github.com/NixOS/nixpkgs/pull/505042)|
| **libkrun** | 1.17.4 | [containers/libkrun](https://github.com/containers/libkrun) PR upstreamed [#505042](https://github.com/NixOS/nixpkgs/pull/505042)|
| **muvm** | 0.5.1 | [AsahiLinux/muvm](https://github.com/AsahiLinux/muvm) Overlay, PR to upstream pending [#505382](https://github.com/NixOS/nixpkgs/pull/505382) |
| **FEX-Emu** | 2603 | [FEX-Emu/FEX](https://github.com/FEX-Emu/FEX) taken directly from nixpkgs-unstable |
| **Steam bootstrap** | 1.0.0.81 | taken directly from nixpkgs-unstable |

All packages are built as overlays on top of nixpkgs-unstable.

## Usage

```sh
nix develop # And then use the components provided by the flake like the `steam-asahi` script
```

You can also use it as a module
  
```nix
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
