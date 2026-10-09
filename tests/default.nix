{
  pkgs,
  nixpkgs,
  module,
  scriptTestSources,
}:
let
  shellScripts =
    pkgs.runCommand "steam-asahi-shell-scripts-test"
      {
        nativeBuildInputs = builtins.attrValues {
          inherit (pkgs)
            bash
            coreutils
            util-linux
            ;
          python314 = pkgs.python314.withPackages (packages: [
            packages.boltons
            packages.msgspec
          ]);
        };
      }
      ''
        diagnostic_output=$(BASH_ENV= PATH= \
          COMMON_SCRIPT=${../src/guest/common.sh} \
          ${pkgs.bash}/bin/bash -c \
          'exec ${pkgs.bash}/bin/bash "$@"' steam-asahi-fex \
          ${../pkgs/steam/fex/guest/diagnostic.sh} \
          'printf "%s" "$PATH"')
        test "$diagnostic_output" = /usr/local/bin:/usr/bin:/bin

        steam_output=$(BASH_ENV= PATH= GIO_EXTRA_MODULES=/host/gio \
          COMMON_SCRIPT=${../src/guest/common.sh} \
          XDG_DATA_DIRS=/host/share \
          STEAM_ASAHI_GUEST_UID=1234 \
          ${pkgs.bash}/bin/bash -c \
          'exec ${pkgs.bash}/bin/bash "$@"' steam-asahi-fex \
          ${../pkgs/steam/fex/guest/steam.sh} \
          ${pkgs.bash}/bin/bash -c \
          'printf "%s|%s|%s|%s|%s|%s" "$1" "$2" "$PULSE_SERVER" "$PATH" "''${GIO_EXTRA_MODULES-unset}" "$XDG_DATA_DIRS"' \
          steam-asahi 'one two' 'semi;colon')
        test "$steam_output" = \
          'one two|semi;colon|unix:/run/user/1234/pulse/native|/usr/local/bin:/usr/bin:/bin|unset|/run/opengl-driver/share:/run/current-system/sw/share:/usr/local/share:/usr/share:/host/share'

        bash ${scriptTestSources}/tests/shell/scripts.sh ${scriptTestSources}
        touch "$out"
      '';
in
{
  steam-arm64-client-layout = pkgs.steam-arm64-client.tests.layout;
  steam-asahi-launcher = pkgs.callPackage ./launchers/fex.nix { };
  steam-asahi-arm64-launcher = pkgs.callPackage ./launchers/arm64.nix { };
  steam-asahi-module = import ./nixos/module.nix {
    inherit nixpkgs;
    inherit module;
    pkgs = pkgs;
  };
  steam-asahi-shell-scripts = shellScripts;
}
