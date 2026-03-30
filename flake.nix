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
          libkrunfw = mkGitHubOverride prev.libkrunfw {
            owner = "containers";
            repo = "libkrunfw";
            version = "5.3.0";
            hash = "sha256-fhG/bP1HzmhyU2N+wnr1074WEGsD9RdTUUBhYUFpWlA=";
            extraAttrs = _: {
              kernelSrc = prev.fetchurl {
                url = "mirror://kernel/linux/kernel/v6.x/linux-6.12.76.tar.xz";
                hash = "sha256-u7Q+g0xG5r1JpcKPIuZ5qTdENATh9lMgTUskkp862JY=";
              };
            };
          };

          libkrun = mkGitHubOverride prev.libkrun {
            owner = "containers";
            repo = "libkrun";
            version = "1.17.4";
            hash = "sha256-Th4vCg3xHb6lbo26IDZES7tLOUAJTebQK2+h3xSYX7U=";
            extraAttrs = old: {
              cargoDeps = prev.rustPlatform.fetchCargoVendor {
                inherit (old) src;
                hash = "sha256-0xpAyNe1jF1OMtc7FXMsejqIv0xKc1ktEvm3rj/mVFU=";
              };
              buildInputs = old.buildInputs ++ [ prev.libcap_ng ];
            };
          };

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
          fex
          ;
        steam-asahi = pkgs.callPackage ./pkgs/steam-asahi { };
        default = self.packages.${system}.steam-asahi;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.muvm
          pkgs.fex
          self.packages.${system}.steam-asahi
        ];

        shellHook = ''
          echo "asahi-steam dev shell"
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
