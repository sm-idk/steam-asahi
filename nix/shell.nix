{ lib, pkgs }:

let
  x86Command = pkgs.writeShellApplication {
    inheritPath = false;
    name = "steam-asahi-x86";
    text = ''
      exec ${lib.meta.getExe pkgs.steam-asahi} "$@"
    '';
  };
  arm64Command = pkgs.writeShellApplication {
    inheritPath = false;
    name = "steam-asahi-arm64";
    text = ''
      exec ${lib.meta.getExe pkgs.steam-asahi-arm64} "$@"
    '';
  };
  arm64TestPackage = pkgs.steam-asahi-arm64.override {
    customSteamHomeDir = "steam-asahi-arm64-test-home";
  };
  arm64TestCommand = pkgs.writeShellApplication {
    inheritPath = false;
    name = "steam-asahi-arm64-test";
    text = ''
      exec ${lib.meta.getExe arm64TestPackage} "$@"
    '';
  };
in
pkgs.mkShellNoCC {
  packages = builtins.attrValues {
    inherit (pkgs)
      uv
      python314
      muvm
      fex
      shellcheck
      steam-asahi
      ;
    inherit x86Command arm64Command arm64TestCommand;
  };

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
}
