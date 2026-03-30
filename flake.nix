{
  description = "Steam on NixOS Asahi Linux (Apple Silicon) via muvm + FEX-Emu";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "aarch64-linux";

      overlay = final: prev: {
        # --- libkrunfw 5.3.0 (kernel 6.12.76) ---
        libkrunfw = prev.libkrunfw.overrideAttrs (old: rec {
          version = "5.3.0";

          src = prev.fetchFromGitHub {
            owner = "containers";
            repo = "libkrunfw";
            tag = "v${version}";
            hash = "sha256-fhG/bP1HzmhyU2N+wnr1074WEGsD9RdTUUBhYUFpWlA=";
          };

          kernelSrc = prev.fetchurl {
            url = "mirror://kernel/linux/kernel/v6.x/linux-6.12.76.tar.xz";
            hash = "sha256-u7Q+g0xG5r1JpcKPIuZ5qTdENATh9lMgTUskkp862JY=";
          };
        });

        # --- libkrun 1.17.4 ---
        libkrun = prev.libkrun.overrideAttrs (old: rec {
          version = "1.17.4";

          src = prev.fetchFromGitHub {
            owner = "containers";
            repo = "libkrun";
            tag = "v${version}";
            hash = "sha256-Th4vCg3xHb6lbo26IDZES7tLOUAJTebQK2+h3xSYX7U=";
          };

          cargoDeps = prev.rustPlatform.fetchCargoVendor {
            inherit src;
            hash = "sha256-0xpAyNe1jF1OMtc7FXMsejqIv0xKc1ktEvm3rj/mVFU=";
          };

          buildInputs = old.buildInputs ++ [ prev.libcap_ng ];
        });

        # --- muvm 0.5.1 ---
        muvm = prev.muvm.overrideAttrs (old: rec {
          version = "0.5.1";

          src = prev.fetchFromGitHub {
            owner = "AsahiLinux";
            repo = "muvm";
            tag = "muvm-${version}";
            hash = "sha256-eXsU2QRJ55gx5RhjT+m9F1KAFqGrd4WwnyR3eMpuIc4=";
          };

          cargoDeps = prev.rustPlatform.importCargoLock {
            lockFile = src + "/Cargo.lock";
          };

          # Override postPatch: /sbin/sysctl reference was removed in 0.5.1
          postPatch = ''
            substituteInPlace crates/muvm/src/guest/bin/muvm-guest.rs \
              --replace-fail "/usr/lib/systemd/systemd-udevd" "${prev.systemd}/lib/systemd/systemd-udevd"
          ''
          + prev.lib.optionalString prev.stdenv.hostPlatform.isAarch64 ''
            substituteInPlace crates/muvm/src/guest/mount.rs \
              --replace-fail "/usr/share/fex-emu" "${final.fex}/share/fex-emu"
          '';
        });

        # --- FEX 2603 (with thunks) ---
        fex = prev.fex.overrideAttrs (old: {
          version = "2603";

          src = prev.fetchFromGitHub {
            owner = "FEX-Emu";
            repo = "FEX";
            tag = "FEX-2603";
            hash = "sha256-rQOqziJ7IizJV3VmAWGo5s2xn2/xnp0sx3VfBtH1JK4=";

            leaveDotGit = true;
            postFetch = ''
              cd $out
              git reset

              # Fetch required submodules for FEX 2603
              git submodule update --init --depth 1 \
                External/Vulkan-Headers \
                External/drm-headers \
                External/jemalloc_glibc \
                External/rpmalloc \
                External/unordered_dense \
                External/vixl \
                Source/Common/cpp-optparse

              find . -name .git -print0 | xargs -0 rm -rf

              # Remove unnecessary directories
              rm -r \
                External/vixl/src/aarch32 \
                External/vixl/test
            '';
          };

          nativeBuildInputs = old.nativeBuildInputs ++ [ prev.git ];

          # Tests can't run on 16K page systems (jemalloc crashes)
          doCheck = false;

          # FEX 2603 needs a git repo for version detection (git_version.h).
          # Create a fake one, then run the original nixpkgs postPatch for thunk path fixups.
          postPatch = ''
            git init
            git config user.email "nix@localhost"
            git config user.name "Nix"
            git add .
            git commit -m "FEX-2603" --quiet
            git tag "FEX-2603"
          ''
          + old.postPatch;
        });
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
          echo "  steam-asahi                                         # launch Steam"
        '';
      };
    };
}
