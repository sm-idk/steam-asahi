{
  description = "Steam on NixOS Asahi Linux (Apple Silicon) via muvm + FEX-Emu";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "aarch64-linux";

      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true; # steam-unwrapped
        overlays = [ self.overlays.default ];
      };
    in
    {
      overlays.default = final: prev: {
        steam-asahi = final.callPackage ./pkgs/steam-asahi { };

        # Temporary packaging-only fix for nixpkgs' fex 2605 under Python 3.14.
        # The old source/version pin is gone: muvm, libkrun, libkrunfw and FEX
        # all come from nixpkgs now. Drop this once nixpkgs adds `packaging` to
        # fex's Python build environment. Replace nixpkgs' incomplete Python
        # env rather than appending: CMake finds the first `python3` on PATH.
        fex = prev.fex.overrideAttrs (old: {
          nativeBuildInputs =
            final.lib.filter (
              input:
              !(
                final.lib.hasPrefix "python3-" (input.name or "") && final.lib.hasSuffix "-env" (input.name or "")
              )
            ) old.nativeBuildInputs
            ++ [
              (final.python3.withPackages (
                ps: with ps; [
                  packaging
                  libclang
                  setuptools
                ]
              ))
            ];
        });
      };

      packages.${system} = {
        inherit (pkgs)
          libkrunfw
          libkrun
          muvm
          fex
          steam-asahi
          ;
        default = pkgs.steam-asahi;
      };

      nixosModules.default = {
        nixpkgs.overlays = [ self.overlays.default ];
        imports = [ ./modules/steam-asahi.nix ];
      };
      nixosModules.steam-asahi = self.nixosModules.default;

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.muvm
          pkgs.fex
          pkgs.steam-asahi
        ];

        shellHook = ''
          echo "steam-asahi dev shell"
          echo "  muvm: $(command -v muvm || echo missing)"
          echo "  FEXBash: $(command -v FEXBash || echo missing)"
          echo ""
          echo "Test commands:"
          echo "  muvm --interactive -- bash -c 'getconf PAGESIZE'   # should print 4096"
          echo "  steam-asahi --fex 'uname -m'                       # should print x86_64"
          echo "  steam-asahi                                        # launch Steam"
        '';
      };
    };
}
