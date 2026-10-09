{
  description = "Steam on NixOS Asahi Linux via x86/FEX or the native ARM64 beta";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      nativeSystem = "aarch64-linux";
      checkSystems = [
        nativeSystem
        "x86_64-linux"
      ];
      pkgsFor = lib.genAttrs checkSystems (
        system:
        import nixpkgs {
          localSystem.system = system;
          config = {
            allowUnfree = true;
            allowUnsupportedSystem = system != nativeSystem;
          };
          overlays = [ self.overlays.default ];
        }
      );
    in
    {
      overlays.default = import ./pkgs/overlay.nix;
      nixosModules.default = {
        imports = [ ./nixos ];
      };
      nixosModules.steam-asahi = self.nixosModules.default;

      packages = lib.mapAttrs (
        system: pkgs:
        {
          steam-asahi-options = pkgs.callPackage ./nix/options.nix {
            inherit nixpkgs;
            module = self.nixosModules.default;
            sourceRoot = self.outPath;
          };
        }
        // lib.optionalAttrs (system == nativeSystem) {
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
        }
      ) pkgsFor;

      checks = lib.mapAttrs (
        system: pkgs:
        import ./nix/checks.nix {
          inherit pkgs nixpkgs;
          module = self.nixosModules.default;
          source = self;
          formatter = self.formatter.${system};
        }
        // lib.optionalAttrs (system == nativeSystem) {
          inherit (pkgs) steam-asahi steam-asahi-arm64;
        }
      ) pkgsFor;

      formatter = lib.mapAttrs (_: pkgs: pkgs.callPackage ./nix/formatter.nix { }) pkgsFor;
      devShells.${nativeSystem}.default = pkgsFor.${nativeSystem}.callPackage ./nix/shell.nix { };
    };
}
