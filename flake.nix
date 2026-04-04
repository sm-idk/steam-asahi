{
  description = "Steam on NixOS Asahi Linux (Apple Silicon) via muvm + FEX-Emu";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "aarch64-linux";
      lib = nixpkgs.lib;

      overlay =
        final: prev:
        let
          mkGitHubOverride =
            pkg:
            {
              owner,
              repo,
              version,
              tag ? "v${version}",
              hash,
              fetchArgs ? { },
              extraAttrs ? (_old: { }),
            }:
            pkg.overrideAttrs (
              old:
              let
                newSrc = prev.fetchFromGitHub (
                  {
                    inherit
                      owner
                      repo
                      tag
                      hash
                      ;
                  }
                  // fetchArgs
                );
              in
              {
                inherit version;
                src = newSrc;
              }
              // (extraAttrs (old // { src = newSrc; }))
            );
        in
        {
          muvm = mkGitHubOverride prev.muvm {
            owner = "AsahiLinux";
            repo = "muvm";
            version = "0.5.1";
            tag = "muvm-0.5.1";
            hash = "sha256-eXsU2QRJ55gx5RhjT+m9F1KAFqGrd4WwnyR3eMpuIc4=";
            extraAttrs = old: {
              cargoDeps = prev.rustPlatform.importCargoLock {
                lockFile = old.src + "/Cargo.lock";
              };
              postPatch = ''
                substituteInPlace crates/muvm/src/guest/bin/muvm-guest.rs \
                  --replace-fail "/usr/lib/systemd/systemd-udevd" "${prev.systemd}/lib/systemd/systemd-udevd"
              ''
              + lib.optionalString prev.stdenv.hostPlatform.isAarch64 ''
                substituteInPlace crates/muvm/src/guest/mount.rs \
                  --replace-fail "/usr/share/fex-emu" "${final.fex}/share/fex-emu"
              '';
            };
          };

          steam-asahi = final.callPackage ./pkgs/steam-asahi { };
        };

      pkgs = import nixpkgs {
        inherit system;
        overlays = [ overlay ];
      };
    in
    {
      overlays.default = overlay;

      packages.${system} = {
        inherit (pkgs)
          libkrunfw
          libkrun
          muvm
          steam-asahi
          ;
        default = self.packages.${system}.steam-asahi;
      };

      nixosModules.default = {
        nixpkgs.overlays = [ overlay ];
        imports = [ ./modules/steam-asahi.nix ];
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.muvm
          pkgs.fex
          self.packages.${system}.steam-asahi
        ];

        shellHook = ''
          echo "steam-asahi dev shell"
          echo "  muvm $(muvm --version 2>&1 || echo 'available')"
          echo "  FEXBash available: $(which FEXBash 2>/dev/null && echo yes || echo no)"
          echo ""
          echo "Test commands:"
          echo "  muvm --interactive -- bash -c 'getconf PAGESIZE'   # should print 4096"
          echo "  muvm --interactive -- FEXBash -c 'uname -m'        # should print x86_64"
          echo "  steam-asahi                                        # launch Steam"
        '';
      };
    };
}
