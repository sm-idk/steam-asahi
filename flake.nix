{
  description = "Steam on NixOS Asahi Linux via x86/FEX or the native ARM64 beta";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "aarch64-linux";

      lib = nixpkgs.lib;
      nixosModuleLocation = __curPos.file + "#nixosModules.default";

      # The launcher tests execute architecture-independent Python and shell code
      pkgsFor = lib.genAttrs [ system "x86_64-linux" ] (
        checkSystem:
        import nixpkgs {
          localSystem.system = checkSystem;
          config = {
            allowUnfree = true;
            allowUnsupportedSystem = checkSystem != system;
          };
          overlays = [ self.overlays.default ];
        }
      );
      pkgs = pkgsFor.${system};

      shellFiles = lib.fileset.unions [
        (lib.fileset.fileFilter (file: file.hasExt "sh") ./pkgs)
        ./pkgs/steam-asahi-arm64/proton/run-proton
        ./pkgs/steam-asahi-arm64/proton/steam-asahi-proton
      ];
      shellSources = lib.fileset.toSource {
        root = ./.;
        fileset = shellFiles;
      };
      scriptTestSources = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          shellFiles
          ./pkgs/scripts/launcher
          ./pkgs/steam-asahi-arm64/tests/check-launcher-imports.py
          ./pkgs/steam-asahi-arm64/tests/run-launcher.py
        ];
      };

      # Match nixpkgs' current formatter setup: semantic cleanup runs first and
      # nixfmt normalizes the result. The same package is both the `nix fmt`
      # entry point and the source-formatting check
      mkFormatter =
        formatterPkgs:
        formatterPkgs.treefmt.withConfig {
          runtimeInputs = [
            formatterPkgs.nixf-diagnose
            formatterPkgs.nixfmt
            formatterPkgs.ruff
            formatterPkgs.shfmt
          ];
          settings = {
            on-unmatched = "debug";
            tree-root-file = "flake.nix";
            formatter = {
              nixf-diagnose = {
                command = lib.meta.getExe formatterPkgs.nixf-diagnose;
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
              python = {
                command = lib.meta.getExe formatterPkgs.ruff;
                includes = [ "*.py" ];
                options = [ "format" ];
              };
              shell = {
                command = lib.meta.getExe formatterPkgs.shfmt;
                includes = [
                  "pkgs/scripts/*.sh"
                  "pkgs/steam-asahi/scripts/*.sh"
                  "pkgs/steam-asahi-arm64/scripts/*.sh"
                  "pkgs/steam-asahi-arm64/proton/run-proton"
                  "pkgs/steam-asahi-arm64/proton/steam-asahi-proton"
                ];
                options = [
                  "-w"
                  "-i"
                  "2"
                  "-ci"
                  "-bn"
                ];
              };
              nixfmt = {
                command = lib.meta.getExe formatterPkgs.nixfmt;
                includes = [ "*.nix" ];
              };
            };
          };
        };

      mkShellScriptsCheck =
        testPkgs:
        testPkgs.runCommand "steam-asahi-shell-scripts-test"
          {
            nativeBuildInputs = [
              testPkgs.bash
              testPkgs.coreutils
              testPkgs.python314
              testPkgs.util-linux
            ];
          }
          ''
            diagnostic_output=$(BASH_ENV= PATH= \
              COMMON_SCRIPT=${./pkgs/scripts/common.sh} \
              ${testPkgs.bash}/bin/bash -c \
              'exec ${testPkgs.bash}/bin/bash "$@"' steam-asahi-fex \
              ${./pkgs/steam-asahi/scripts/fex-diagnostic.sh} \
              'printf "%s" "$PATH"')
            test "$diagnostic_output" = /usr/local/bin:/usr/bin:/bin

            steam_output=$(BASH_ENV= PATH= GIO_EXTRA_MODULES=/host/gio \
              COMMON_SCRIPT=${./pkgs/scripts/common.sh} \
              XDG_DATA_DIRS=/host/share \
              STEAM_ASAHI_GUEST_UID=1234 \
              ${testPkgs.bash}/bin/bash -c \
              'exec ${testPkgs.bash}/bin/bash "$@"' steam-asahi-fex \
              ${./pkgs/steam-asahi/scripts/fex-steam.sh} \
              ${testPkgs.bash}/bin/bash -c \
              'printf "%s|%s|%s|%s|%s|%s" "$1" "$2" "$PULSE_SERVER" "$PATH" "''${GIO_EXTRA_MODULES-unset}" "$XDG_DATA_DIRS"' \
              steam-asahi 'one two' 'semi;colon')
            test "$steam_output" = \
              'one two|semi;colon|unix:/run/user/1234/pulse/native|/usr/local/bin:/usr/bin:/bin|unset|/run/opengl-driver/share:/run/current-system/sw/share:/usr/local/share:/usr/share:/host/share'

            bash ${scriptTestSources}/pkgs/steam-asahi-arm64/tests/scripts.sh ${scriptTestSources}
            touch "$out"
          '';

      mkChecks = testPkgs: {
        formatting = (mkFormatter testPkgs).check self;
        shellcheck = testPkgs.testers.shellcheck {
          name = "steam-asahi";
          src = shellSources;
        };
        steam-arm64-client-layout = testPkgs.steam-arm64-client.tests.layout;
        steam-arm64-client-update-script = testPkgs.steam-arm64-client.tests.updateScript;
        steam-asahi-launcher = testPkgs.callPackage ./pkgs/steam-asahi/tests/launcher.nix { };
        steam-asahi-arm64-launcher = testPkgs.callPackage ./pkgs/steam-asahi-arm64/tests/launcher.nix { };
        steam-asahi-module = import ./modules/tests.nix {
          inherit nixpkgs;
          module = self.nixosModules.default;
          pkgs = testPkgs;
        };
        steam-asahi-shell-scripts = mkShellScriptsCheck testPkgs;
      };
    in
    {
      overlays.default = import ./pkgs/overlay.nix;

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

      checks = lib.mapAttrs (
        checkSystem: testPkgs:
        mkChecks testPkgs
        // lib.optionalAttrs (checkSystem == system) {
          inherit (testPkgs) steam-asahi steam-asahi-arm64;
        }
      ) pkgsFor;

      nixosModules.default = {
        _class = "nixos";
        _file = nixosModuleLocation;
        key = nixosModuleLocation;

        nixpkgs.overlays = [ self.overlays.default ];
        imports = [ ./modules/steam-asahi.nix ];
      };
      nixosModules.steam-asahi = self.nixosModules.default;

      formatter = lib.mapAttrs (_: mkFormatter) pkgsFor;

      devShells.${system}.default =
        let
          x86Command = pkgs.writeShellApplication {
            inheritPath = false;
            name = "steam-asahi-x86";
            text = ''
              exec ${nixpkgs.lib.meta.getExe pkgs.steam-asahi} "$@"
            '';
          };
          arm64Command = pkgs.writeShellApplication {
            inheritPath = false;
            name = "steam-asahi-arm64";
            text = ''
              exec ${nixpkgs.lib.meta.getExe pkgs.steam-asahi-arm64} "$@"
            '';
          };
          arm64TestPackage = pkgs.steam-asahi-arm64.override {
            customSteamHomeDir = "steam-asahi-arm64-test-home";
          };
          arm64TestCommand = pkgs.writeShellApplication {
            inheritPath = false;
            name = "steam-asahi-arm64-test";
            text = ''
              exec ${nixpkgs.lib.meta.getExe arm64TestPackage} "$@"
            '';
          };
        in
        pkgs.mkShellNoCC {
          packages = [
            pkgs.uv
            pkgs.python314
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
            echo "  steam-asahi-arm64-test --force-proton APPID"
          '';
        };
    };
}
