{
  description = "Steam on NixOS Asahi Linux via x86/FEX or the native ARM64 beta";

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
        steam-arm64-client = final.callPackage ./pkgs/steam-arm64-client { };
        steam-asahi-arm64 = final.callPackage ./pkgs/steam-asahi-arm64 { };
        steam-asahi = final.callPackage ./pkgs/steam-asahi { };

        # Backport https://github.com/NixOS/nixpkgs/pull/540511 for FEX 2605
        # under Python 3.14. Drop this override once the locked nixpkgs contains
        # that change. Replace the old Python env rather than appending another:
        # CMake finds the first `python3` on PATH.
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
          steam-arm64-client
          steam-asahi-arm64
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
          pkgs.steam-asahi-arm64
        ];

        shellHook = ''
          echo "steam-asahi dev shell"
          echo "  muvm: $(command -v muvm || echo missing)"
          echo "  FEXBash: $(command -v FEXBash || echo missing)"
          echo ""
          echo "Backend packages:"
          echo "  nix run .#steam-asahi         # x86 client through FEX (default)"
          echo "  nix run .#steam-asahi-arm64   # native ARM64 public beta"
          echo ""
          echo "Diagnostics:"
          echo "  steam-asahi --fex 'uname -m'"
          echo "  nix run .#steam-asahi-arm64 -- --guest uname -m"
        '';
      };
    };
}
