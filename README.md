# steam-asahi

Nix flake to run Steam on NixOS Asahi Linux (Apple Silicon) via muvm + FEX-Emu.

<img width="3444" height="1967" alt="Image" src="https://github.com/user-attachments/assets/c8b4902b-3e69-43d7-8a21-29f91bb57f8f" />

> Picture generously provided by EliSaado from the #asahi-alt oftc IRC

## Acknowledgements

Thanks to [ooonea's Codeberg fork](https://codeberg.org/ooonea/steam-asahi)
for picking this back up and validating several fixes that are now carried here too:
dropping the obsolete muvm/libkrun/libkrunfw source pins, handling FEX's XDG
rootfs paths, adding a muvm memory cap, adding `steam-asahi --fex` diagnostics,
avoiding the interactive rootfs fetcher fallback, and documenting the swap/zswap
setup that makes this usable on low-RAM Apple Silicon machines.

## Warning

> [!WARNING]
> **This project was primarily written by an LLM (AI). Review the code yourself before running it. Use at your own risk.**

The launcher performs several potentially dangerous operations at runtime:

- **Bind-mounts over `/bin`, `/usr`, and `/etc`** inside the muvm guest to create an FHS-compatible environment for Steam
- **Sets suid root on `fusermount` and `fusermount3`** (copied to `/run/wrappers/bin/`) so FEX can mount its rootfs overlay
- **Downloads a ~1.3GB FEX rootfs** (Fedora 43) on first run via `FEXRootFSFetcher`
- **Installs Steam bootstrap files** into `~/.local/share/steam-asahi/`

## Components

The old local source overlays for muvm, libkrun, and libkrunfw have been removed:
the required NixOS/Asahi fixes are upstream in nixpkgs now. The nixpkgs PR links
below are kept as provenance for the fixes this repo originally carried as overlays.

| Component | Version in current lock | Source / provenance |
|-----------|-------------------------|---------------------|
| **libkrunfw** | 5.5.0 (kernel 6.12.91) | stock nixpkgs-unstable; upstreamed via [NixOS/nixpkgs#505042](https://github.com/NixOS/nixpkgs/pull/505042) |
| **libkrun** | 1.19.0 | stock nixpkgs-unstable; upstreamed via [NixOS/nixpkgs#505042](https://github.com/NixOS/nixpkgs/pull/505042) |
| **muvm** | 0.6.0 | stock nixpkgs-unstable; NixOS guest path/FEX share patches upstreamed via [NixOS/nixpkgs#505382](https://github.com/NixOS/nixpkgs/pull/505382) |
| **FEX-Emu** | 2605 | stock nixpkgs-unstable, with a temporary packaging-only Python `packaging` build fix |
| **virglrenderer** | 1.3.0 | stock nixpkgs-unstable; Asahi DRM native context is upstream |
| **Steam bootstrap** | 1.0.0.85 | `steam-unwrapped` from nixpkgs-unstable |

The overlay now only adds the `steam-asahi` launcher package plus the temporary FEX packaging hotfix noted above.

## Upstreaming notes

Things that should live in nixpkgs rather than this flake long-term:

- **FEX Python build environment hotfix**: add the missing Python `packaging`
  dependency to nixpkgs' `fex` package and remove this flake's overlay once
  merged.
- **First-class `steam-asahi` package/module** if nixpkgs wants to support this
  stack directly. That should carry the muvm/FEX-specific launcher workarounds:
  FEX XDG rootfs detection, the muvm memory cap, the Steam/PressureVessel FHS
  shims, Vulkan ICD/layer import handling, locale/charmap exposure, and
  module-level conflict handling for regular `programs.steam` / host 32-bit
  graphics.

Things that should remain user/runtime state, not nixpkgs: the Steam client
self-update tree, game libraries, shader caches, Proton prefixes, and the FEX
rootfs downloaded by `FEXRootFSFetcher` unless nixpkgs grows an explicit pinned
rootfs package.

## Usage

```sh
nix develop # then run steam-asahi
```

You can also use it as a NixOS module:

```nix
{
  inputs = {
    steam-asahi = {
      url = "github:sm-idk/steam-asahi";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, steam-asahi, ... }:
    {
      nixosConfigurations."«hostname»" = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          steam-asahi.nixosModules.default
          {
            programs.steam-asahi = {
              enable = true;
              # Optional: on 8 GiB machines this leaves the compositor headroom.
              memoryMiB = 6144;
            };

            # steam-unwrapped is unfree.
            nixpkgs.config.allowUnfree = true;

            # muvm is rootless, but needs /dev/kvm access.
            users.users."«username»".extraGroups = [ "kvm" ];
          }
        ];
      };
    };
}
```

Do **not** enable `programs.steam` or `hardware.graphics.enable32Bit` on
`aarch64-linux`; 32-bit x86 support comes from the FEX rootfs. When
`programs.steam-asahi.enable = true`, this module force-disables both
incompatible options and emits an evaluation warning if something tries to enable
them.

## Recommended host settings

Steam + Proton + FEX can put a lot of pressure on 8 GiB and 16 GiB systems. Mirroring Fedora Asahi's memory tier helps a lot:

```nix
swapDevices = [
  {
    device = "/var/lib/swapfile";
    size = 12 * 1024; # MiB
  }
];

boot.kernelParams = [
  "zswap.enabled=1"
  "zswap.compressor=zstd"
  "zswap.zpool=zsmalloc"
  "zswap.max_pool_percent=20"
];

boot.kernel.sysctl = {
  "vm.swappiness" = 100;
  "vm.page-cluster" = 0;
  "vm.watermark_scale_factor" = 125;
  "vm.max_map_count" = 1048576;
};
```

Audio expects PipeWire's PulseAudio compatibility socket:

```nix
services.pipewire = {
  enable = true;
  alsa.enable = true;
  pulse.enable = true;
};
```

## Diagnostics

Run these in order:

```sh
muvm --interactive -- bash -c 'getconf PAGESIZE' # should print 4096
steam-asahi --fex 'uname -m'                     # should print x86_64
steam-asahi --fex 'vulkaninfo --summary'         # should list the Apple GPU
```
