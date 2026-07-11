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

      devShells.${system}.default =
        let
          x86Command = pkgs.writeShellScriptBin "steam-asahi-x86" ''
            exec ${pkgs.steam-asahi}/bin/steam-asahi "$@"
          '';
          arm64Command = pkgs.writeShellScriptBin "steam-asahi-arm64" ''
            exec ${pkgs.steam-asahi-arm64}/bin/steam-asahi "$@"
          '';
          arm64TestCommand = pkgs.writeShellScriptBin "steam-asahi-arm64-test" ''
            source_home="$HOME"
            source_data_home="''${XDG_DATA_HOME:-$HOME/.local/share}"
            test_home="''${STEAM_ASAHI_ARM64_TEST_HOME:-$source_data_home/steam-asahi-arm64-test-home}"

            import_login=false
            if [[ "''${1:-}" == "--import-login" ]]; then
              import_login=true
              shift
            fi

            mkdir -p "$test_home"
            if [[ "$import_login" == true ]]; then
              source_steam="$source_data_home/Steam"
              test_steam="$test_home/.local/share/Steam"
              if [[ ! -f "$source_steam/local.vdf" || ! -f "$source_steam/config/loginusers.vdf" || ! -f "$source_steam/config/config.vdf" ]]; then
                echo "ERROR: no complete logged-in Steam state found under $source_steam" >&2
                exit 1
              fi
              mkdir -p "$test_steam/config" "$test_home/.steam"
              cp -a "$source_steam/local.vdf" "$test_steam/local.vdf"
              cp -a "$source_steam/config/loginusers.vdf" "$test_steam/config/loginusers.vdf"
              cp -a "$source_steam/config/config.vdf" "$test_steam/config/config.vdf"
              if [[ -f "$source_home/.steam/registry.vdf" ]]; then
                cp -a "$source_home/.steam/registry.vdf" "$test_home/.steam/registry.vdf"
              fi
              echo "Imported a copy of the normal Steam login into isolated test state."
            fi

            export HOME="$test_home"
            export XDG_DATA_HOME="$test_home/.local/share"
            export XDG_CONFIG_HOME="$test_home/.config"
            export XDG_CACHE_HOME="$test_home/.cache"
            export XDG_STATE_HOME="$test_home/.local/state"
            echo "Using isolated ARM64 Steam test state: $test_home"
            exec ${pkgs.steam-asahi-arm64}/bin/steam-asahi "$@"
          '';
        in
        pkgs.mkShell {
          packages = [
            pkgs.muvm
            pkgs.fex
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
            echo "  steam-asahi-arm64        # ARM64 beta, normal Steam state"
            echo "  steam-asahi-arm64-test   # ARM64 beta, isolated test state (--import-login supported)"
            echo ""
            echo "ARM64 diagnostics:"
            echo "  steam-asahi-arm64 --guest uname -m"
            echo "  steam-asahi-arm64 --guest getconf PAGESIZE"
          '';
        };
    };
}
