{
  description = "Steam on NixOS Asahi Linux via x86/FEX or the native ARM64 beta";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "aarch64-linux";

      nixosModuleLocation = __curPos.file + "#nixosModules.default";

      pkgs = import nixpkgs {
        localSystem = { inherit system; };
        config.allowUnfree = true; # steam-unwrapped
        overlays = [ self.overlays.default ];
      };

      # Keep the NixOS VM focused on this module. Steam and muvm have their own
      # package checks; the VM only needs a small executable plus muvm's policy
      # source layout to exercise the module's runtime integration.
      vmTestOverlay = final: _prev: {
        muvm =
          let
            source = final.runCommand "muvm-test-source" { } ''
              mkdir -p \
                "$out/share/wireplumber/wireplumber.conf.d" \
                "$out/share/wireplumber/scripts/client"
              touch \
                "$out/share/wireplumber/wireplumber.conf.d/50-muvm-access.conf" \
                "$out/share/wireplumber/scripts/client/access-muvm.lua"
            '';
          in
          (final.writeShellApplication {
            name = "muvm";
            text = ''
              printf '%s\n' 'muvm test double'
            '';
          }).overrideAttrs
            {
              inherit source;
              pname = "muvm";
              src = source;
              version = "test";
            };
      };

      aarch64VmNodePkgs = pkgs.extend vmTestOverlay;
      x86VmNodePkgs = x86TestPkgs.extend vmTestOverlay;

      # These tests execute only architecture-independent shell code, so keep
      # them runnable from the x86_64 machines commonly used for development.
      x86TestPkgs = import nixpkgs {
        localSystem.system = "x86_64-linux";
        config = {
          allowUnfree = true;
          allowUnsupportedSystem = true;
        };
        overlays = [ self.overlays.default ];
      };

      shellSources = nixpkgs.lib.fileset.toSource {
        root = ./.;
        fileset = nixpkgs.lib.fileset.unions [
          ./pkgs/steam-asahi/scripts/fex-diagnostic.sh
          ./pkgs/steam-asahi/scripts/fex-steam.sh
          ./pkgs/steam-asahi/scripts/init.sh
          ./pkgs/steam-asahi/scripts/launcher.sh
          ./pkgs/steam-asahi/scripts/lspci.sh
          ./pkgs/steam-asahi-arm64/proton/run-proton
          ./pkgs/steam-asahi-arm64/proton/steam-asahi-proton
          ./pkgs/steam-asahi-arm64/scripts/guest.sh
          ./pkgs/steam-asahi-arm64/scripts/init.sh
          ./pkgs/steam-asahi-arm64/scripts/launcher.sh
          ./pkgs/steam-asahi-arm64/scripts/lspci.sh
          ./pkgs/steam-asahi-arm64/tests/scripts.sh
        ];
      };

      mkShellChecks =
        testPkgs:
        let
          style =
            testPkgs.runCommand "steam-asahi-shell-style"
              {
                nativeBuildInputs = [
                  testPkgs.findutils
                  testPkgs.gawk
                  testPkgs.gnugrep
                ];
              }
              ''
                if grep -R -n $'\t' ${shellSources}; then
                  printf '%s\n' 'Shell sources must use spaces, not tabs.' >&2
                  exit 1
                fi
                if grep -R -nE '[[:blank:]]+$' ${shellSources}; then
                  printf '%s\n' 'Shell sources have trailing whitespace.' >&2
                  exit 1
                fi
                if grep -R -n $'\r' ${shellSources}; then
                  printf '%s\n' 'Shell sources must use Unix line endings.' >&2
                  exit 1
                fi

                mapfile -d "" shell_files \
                  < <(find ${shellSources} -type f -print0)
                for shell_file in "''${shell_files[@]}"; do
                  IFS= read -r first_line < "''${shell_file}"
                  case "''${first_line}" in
                    '#!/usr/bin/env bash')
                      for option in errexit nounset pipefail; do
                        if ! grep -Fqx "set -o ''${option}" \
                          "''${shell_file}"; then
                          printf '%s: missing strict option %s\n' \
                            "''${shell_file}" "''${option}" >&2
                          exit 1
                        fi
                      done
                      if ! grep -Fqx 'main() {' "''${shell_file}"; then
                        printf '%s: missing main function\n' \
                          "''${shell_file}" >&2
                        exit 1
                      fi
                      ;;
                    '#!/bin/sh') ;;
                    *)
                      printf '%s: unsupported shell interpreter: %s\n' \
                        "''${shell_file}" "''${first_line}" >&2
                      exit 1
                      ;;
                  esac
                done

                awk '
                  length($0) > 80 {
                    printf "%s:%d: line exceeds 80 characters\n", FILENAME, FNR
                    failed = 1
                  }
                  END { exit failed }
                ' "''${shell_files[@]}"
                touch "$out"
              '';
        in
        {
          shellcheck = testPkgs.testers.shellcheck {
            name = "steam-asahi";
            src = shellSources;
          };
          shell-style = style;
        };

      # Match nixpkgs' current formatter setup: semantic cleanup runs first and
      # nixfmt normalizes the result. The same package is both the `nix fmt`
      # entry point and the source-formatting check.
      mkFormatter =
        formatterPkgs:
        formatterPkgs.treefmt.withConfig {
          runtimeInputs = [
            formatterPkgs.nixf-diagnose
            formatterPkgs.nixfmt
          ];
          settings = {
            on-unmatched = "debug";
            tree-root-file = "flake.nix";
            formatter = {
              nixf-diagnose = {
                command = nixpkgs.lib.getExe formatterPkgs.nixf-diagnose;
                includes = [ "*.nix" ];
                options = [
                  "--auto-fix"
                  "--ignore=sema-unused-def-lambda-noarg-formal"
                  "--ignore=sema-unused-def-lambda-witharg-arg"
                  "--ignore=sema-unused-def-lambda-witharg-formal"
                  "--ignore=sema-unused-def-let"
                  "--ignore=sema-primop-removed-prefix"
                  "--ignore=sema-primop-overridden"
                  "--ignore=sema-constant-overridden"
                  "--ignore=sema-primop-unknown"
                ];
                priority = -1;
              };
              nixfmt = {
                command = nixpkgs.lib.getExe formatterPkgs.nixfmt;
                includes = [ "*.nix" ];
              };
            };
          };
        };

      aarch64Formatter = mkFormatter pkgs;
      x86Formatter = mkFormatter x86TestPkgs;

      x86ShellScriptsCheck =
        x86TestPkgs.runCommand "steam-asahi-shell-scripts-test"
          {
            nativeBuildInputs = [
              x86TestPkgs.bash
              x86TestPkgs.coreutils
              x86TestPkgs.shellcheck
            ];
          }
          ''
            shellcheck \
              ${./pkgs/steam-asahi/scripts/fex-diagnostic.sh} \
              ${./pkgs/steam-asahi/scripts/fex-steam.sh} \
              ${./pkgs/steam-asahi/scripts/init.sh} \
              ${./pkgs/steam-asahi/scripts/launcher.sh} \
              ${./pkgs/steam-asahi/scripts/lspci.sh} \
              ${./pkgs/steam-asahi-arm64/scripts/guest.sh} \
              ${./pkgs/steam-asahi-arm64/scripts/init.sh} \
              ${./pkgs/steam-asahi-arm64/scripts/launcher.sh} \
              ${./pkgs/steam-asahi-arm64/scripts/lspci.sh} \
              ${./pkgs/steam-asahi-arm64/tests/scripts.sh}
            shellcheck --shell=sh \
              ${./pkgs/steam-asahi-arm64/proton/run-proton} \
              ${./pkgs/steam-asahi-arm64/proton/steam-asahi-proton}

            diagnostic_output=$(BASH_ENV= PATH= \
              ${x86TestPkgs.bash}/bin/bash -c \
              'exec ${x86TestPkgs.bash}/bin/bash "$@"' steam-asahi-fex \
              ${./pkgs/steam-asahi/scripts/fex-diagnostic.sh} \
              'printf "%s" "$PATH"')
            test "$diagnostic_output" = /usr/local/bin:/usr/bin:/bin

            steam_output=$(BASH_ENV= PATH= GIO_EXTRA_MODULES=/host/gio \
              XDG_DATA_DIRS=/host/share \
              STEAM_ASAHI_GUEST_UID=1234 \
              ${x86TestPkgs.bash}/bin/bash -c \
              'exec ${x86TestPkgs.bash}/bin/bash "$@"' steam-asahi-fex \
              ${./pkgs/steam-asahi/scripts/fex-steam.sh} \
              ${x86TestPkgs.bash}/bin/bash -c \
              'printf "%s|%s|%s|%s|%s|%s" "$1" "$2" "$PULSE_SERVER" "$PATH" "''${GIO_EXTRA_MODULES-unset}" "$XDG_DATA_DIRS"' \
              steam-asahi 'one two' 'semi;colon')
            test "$steam_output" = \
              'one two|semi;colon|unix:/run/user/1234/pulse/native|/usr/local/bin:/usr/bin:/bin|unset|/run/opengl-driver/share:/run/current-system/sw/share:/usr/local/share:/usr/share:/host/share'

            bash ${./pkgs/steam-asahi-arm64/tests/scripts.sh} ${./.}
            touch "$out"
          '';

      nixosModuleCheck =
        testPkgs:
        import ./modules/tests.nix {
          inherit nixpkgs;
          module = self.nixosModules.default;
          pkgs = testPkgs;
        };

      nixosVmTest =
        {
          hostPkgs,
          nodePkgs,
          pretendAarch64 ? false,
        }:
        import ./modules/vm-test.nix {
          inherit
            hostPkgs
            nodePkgs
            pretendAarch64
            ;
          module = ./modules/steam-asahi.nix;
        };

      aarch64NixosVmTest = nixosVmTest {
        hostPkgs = pkgs;
        nodePkgs = aarch64VmNodePkgs;
      };

      # The evaluation test separately proves that real x86 configurations are
      # rejected. Here only the module-local platform value is replaced so an
      # ordinary x86 contributor can boot-test the remaining NixOS integration.
      x86NixosVmTest = nixosVmTest {
        hostPkgs = x86TestPkgs;
        nodePkgs = x86VmNodePkgs;
        pretendAarch64 = true;
      };
    in
    {
      overlays.default = final: prev: {
        steam-arm64-client = final.callPackage ./pkgs/steam-arm64-client { };
        steam-asahi-arm64 = final.callPackage ./pkgs/steam-asahi-arm64 { };
        steam-asahi = final.callPackage ./pkgs/steam-asahi { };

        fex = prev.fex.overrideAttrs (old: {
          postPatch = (old.postPatch or "") + ''
            # FEX measures this timeout with CNTVCT_EL0 but tests it against a
            # separate host clock. Allow a small amount of clock drift while
            # still checking that the 250 ms timeout was observed.
            substituteInPlace FEXCore/unittests/APITests/FutexSpinTest.cpp \
              --replace-fail \
                'REQUIRE(std::chrono::duration_cast<std::chrono::nanoseconds>(diff) >= std::chrono::duration_cast<std::chrono::nanoseconds>(SleepAmount));' \
                'REQUIRE(std::chrono::duration_cast<std::chrono::nanoseconds>(diff) >= std::chrono::duration_cast<std::chrono::nanoseconds>(SleepAmount - std::chrono::milliseconds(1)));'
          '';
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

      checks.${system} = {
        formatting = aarch64Formatter.check self;
        steam-arm64-client-layout = pkgs.steam-arm64-client.tests.layout;
        steam-arm64-client-update-script = pkgs.steam-arm64-client.tests.updateScript;
        steam-asahi = pkgs.steam-asahi;
        steam-asahi-launcher = pkgs.callPackage ./pkgs/steam-asahi/tests/launcher.nix { };
        steam-asahi-module = nixosModuleCheck pkgs;
        steam-asahi-nixos-vm = aarch64NixosVmTest;
        steam-asahi-source-scripts = pkgs.steam-asahi.tests.sourceScripts;
        steam-asahi-arm64 = pkgs.steam-asahi-arm64;
        steam-asahi-arm64-launcher = pkgs.callPackage ./pkgs/steam-asahi-arm64/tests/launcher.nix { };
        steam-asahi-arm64-proton-scripts = pkgs.steam-asahi-arm64.tests.protonScripts;
        steam-asahi-arm64-source-scripts = pkgs.steam-asahi-arm64.tests.sourceScripts;
      }
      // mkShellChecks pkgs;

      checks.x86_64-linux = {
        formatting = x86Formatter.check self;
        steam-arm64-client-layout = x86TestPkgs.steam-arm64-client.tests.layout;
        steam-arm64-client-update-script = x86TestPkgs.steam-arm64-client.tests.updateScript;
        steam-asahi-launcher = x86TestPkgs.callPackage ./pkgs/steam-asahi/tests/launcher.nix { };
        steam-asahi-arm64-launcher =
          x86TestPkgs.callPackage ./pkgs/steam-asahi-arm64/tests/launcher.nix
            { };
        steam-asahi-module = nixosModuleCheck x86TestPkgs;
        steam-asahi-nixos-vm = x86NixosVmTest;
        steam-asahi-shell-scripts = x86ShellScriptsCheck;
      }
      // mkShellChecks x86TestPkgs;

      nixosModules.default = {
        _class = "nixos";
        _file = nixosModuleLocation;
        key = nixosModuleLocation;

        nixpkgs.overlays = [ self.overlays.default ];
        imports = [ ./modules/steam-asahi.nix ];
      };
      nixosModules.steam-asahi = self.nixosModules.default;

      formatter = {
        ${system} = aarch64Formatter;
        x86_64-linux = x86Formatter;
      };

      devShells.${system}.default =
        let
          x86Command = pkgs.writeShellApplication {
            inheritPath = false;
            name = "steam-asahi-x86";
            text = ''
              exec ${pkgs.steam-asahi}/bin/steam-asahi "$@"
            '';
          };
          arm64Command = pkgs.writeShellApplication {
            inheritPath = false;
            name = "steam-asahi-arm64";
            text = ''
              exec ${pkgs.steam-asahi-arm64}/bin/steam-asahi "$@"
            '';
          };
          arm64TestPackage = pkgs.steam-asahi-arm64.override {
            customSteamHomeDir = "steam-asahi-arm64-test-home";
          };
          arm64TestCommand = pkgs.writeShellApplication {
            inheritPath = false;
            name = "steam-asahi-arm64-test";
            text = ''
              exec ${arm64TestPackage}/bin/steam-asahi "$@"
            '';
          };
        in
        pkgs.mkShellNoCC {
          packages = [
            pkgs.muvm
            pkgs.fex
            pkgs.shellcheck
            pkgs.steam-asahi
            x86Command
            arm64Command
            arm64TestCommand
          ];

          shellHook = ''
            echo "steam-asahi dev shell"
            echo "  muvm: $(command -v muvm || echo missing)"
            echo "  FEXBash: $(command -v FEXBash || echo missing)"
            echo ""
            echo "Backend commands:"
            echo "  steam-asahi              # x86/FEX default"
            echo "  steam-asahi-x86          # explicit x86/FEX backend"
            echo "  steam-asahi-arm64        # ARM64 beta, isolated state by default"
            echo "  steam-asahi-arm64-test   # ARM64 beta, separate development test state"
            echo ""
            echo "ARM64 diagnostics:"
            echo "  steam-asahi-arm64 --guest uname -m"
            echo "  steam-asahi-arm64 --guest getconf PAGESIZE"
          '';
        };
    };
}
