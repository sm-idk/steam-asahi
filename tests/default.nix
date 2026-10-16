{
  pkgs,
  nixpkgs,
  module,
  scriptTestSources,
}:
let
  scripts = pkgs.callPackage ../lib/guest/scripts.nix { };
  diagnostic = scripts.renderSource "test-fex-diagnostic.sh" ../pkgs/steam/fex/guest/diagnostic.nix;
  steam = scripts.renderSource "test-fex-steam.sh" ../pkgs/steam/fex/guest/steam.nix;
  shellTests = pkgs.callPackage ./shell/scripts.nix { inherit scriptTestSources; };
  shellScripts =
    pkgs.runCommand "steam-asahi-shell-scripts-test"
      {
        nativeBuildInputs = builtins.attrValues {
          inherit (pkgs)
            bash
            coreutils
            util-linux
            ;
          python315 = pkgs.python315.withPackages (packages: [
            packages.boltons
            packages.msgspec
          ]);
        };
      }
      ''
        diagnostic_output=$(BASH_ENV= PATH= \
          ${pkgs.bash}/bin/bash -c \
          'exec ${pkgs.bash}/bin/bash "$@"' steam-asahi-fex \
          ${diagnostic} \
          'printf "%s" "$PATH"')
        test "$diagnostic_output" = /usr/local/bin:/usr/bin:/bin

        steam_output=$(BASH_ENV= PATH= GIO_EXTRA_MODULES=/host/gio \
          STEAM_RUNTIME=/legacy/runtime STEAM_RUNTIME_LIBRARY_PATH=/legacy/lib \
          XDG_DATA_DIRS=/host/share \
          STEAM_ASAHI_GUEST_UID=1234 \
          ${pkgs.bash}/bin/bash -c \
          'exec ${pkgs.bash}/bin/bash "$@"' steam-asahi-fex \
          ${steam} \
          ${pkgs.bash}/bin/bash -c \
          'printf "%s|%s|%s|%s|%s|%s|%s|%s" "$1" "$2" "$PULSE_SERVER" "$PATH" "''${GIO_EXTRA_MODULES-unset}" "$XDG_DATA_DIRS" "''${STEAM_RUNTIME-unset}" "''${STEAM_RUNTIME_LIBRARY_PATH-unset}"' \
          steam-asahi 'one two' 'semi;colon')
        test "$steam_output" = \
          'one two|semi;colon|unix:/run/user/1234/pulse/native|/usr/local/bin:/usr/bin:/bin|unset|/run/opengl-driver/share:/run/current-system/sw/share:/usr/local/share:/usr/share:/host/share|unset|unset'

        # Steam's update restart must retain the complete argument vector
        restart_client="$TMPDIR/restart-client"
        cat > "$restart_client" <<'SH'
        #!${pkgs.bash}/bin/bash
        printf '%s\n' "$@" >> "$RESTART_LOG"
        if [[ ! -e "$RESTART_MARKER" ]]; then
          : > "$RESTART_MARKER"
          exit 42
        fi
        exit 7
        SH
        chmod +x "$restart_client"
        status=0
        RESTART_LOG="$TMPDIR/restart.log" \
          RESTART_MARKER="$TMPDIR/restarted" \
          STEAM_ASAHI_GUEST_UID=1234 \
          bash ${steam} \
          "$restart_client" 'one two' 'semi;colon' || status=$?
        test "$status" = 7
        printf '%s\n' 'one two' 'semi;colon' 'one two' 'semi;colon' \
          > "$TMPDIR/restart-expected"
        cmp "$TMPDIR/restart-expected" "$TMPDIR/restart.log"

        ${pkgs.lib.getExe shellTests}
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
