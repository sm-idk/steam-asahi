{ lib, pkgs }:

let
  commands =
    lib.mapAttrsToList
      (
        name: package:
        pkgs.writeShellApplication {
          inherit name;
          inheritPath = false;
          text = ''
            exec ${lib.getExe package} "$@"
          '';
        }
      )
      {
        steam-asahi-x64 = pkgs.steam-asahi;
        steam-asahi-arm64 = pkgs.steam-asahi-arm64;
        steam-asahi-arm64-test = pkgs.steam-asahi-arm64.override {
          customSteamHomeDir = "steam-asahi-arm64-test-home";
        };
      };
in
pkgs.mkShellNoCC {
  UV_PYTHON = lib.meta.getExe pkgs.python315;

  packages =
    builtins.attrValues {
      inherit (pkgs)
        uv
        python315
        muvm
        fex
        shellcheck
        steam-asahi
        ;
    }
    ++ commands;

  shellHook = ''
    echo "steam-asahi dev shell"
    echo "  muvm: $(command -v muvm || echo missing)"
    echo "  FEXBash: $(command -v FEXBash || echo missing)"
    echo ""
    echo "Backend commands:"
    echo "  steam-asahi              # x86_64/FEX default"
    echo "  steam-asahi-x64          # explicit x86_64/FEX backend"
    echo "  steam-asahi-arm64        # ARM64 beta, isolated state by default"
    echo "  steam-asahi-arm64-test   # ARM64 beta, separate development test state"
    echo ""
    echo "ARM64 diagnostics:"
    echo "  steam-asahi-arm64 --guest uname -m"
    echo "  steam-asahi-arm64 --guest getconf PAGESIZE"
    echo "  steam-asahi-arm64-test --force-proton APPID"
  '';
}
