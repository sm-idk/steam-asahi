{
  lib,
  runCommand,
  writeShellApplication,
  steam-asahi,
}:

let
  fakeMuvm = writeShellApplication {
    name = "muvm";
    text = ''
      printf '%s\n' "$@" > "$HOME/muvm-arguments"
    '';
  };

  fakeFex = writeShellApplication {
    name = "FEXRootFSFetcher";
    text = ''
      printf '%s\n' 'unexpected FEX rootfs fetch' >&2
      exit 99
    '';
  };

  fakeSteamSource = runCommand "fake-steam-source" { } ''
    mkdir -p "$out"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$out/bin_steam.sh"
    touch \
      "$out/bootstraplinux_ubuntu12_32.tar.xz" \
      "$out/steam_subscriber_agreement.txt"
  '';

  fakeSteam =
    runCommand "fake-steam-unwrapped"
      {
        version = "test";
        src = fakeSteamSource;
      }
      ''
        mkdir -p "$out/share/icons"
      '';

  package = steam-asahi.override {
    muvm = fakeMuvm;
    fex = fakeFex;
    steam-unwrapped = fakeSteam;
    memoryMiB = 4096;
    vramMiB = 2048;
    publishPorts = [
      "27036/udp"
      "27040/tcp"
    ];
    extraEnv.TEST_ENVIRONMENT = "value with spaces";
  };
in
runCommand "steam-asahi-launcher-test" { } ''
  export HOME="$TMPDIR/home with spaces"
  export XDG_CONFIG_HOME="$HOME/config"
  export XDG_DATA_HOME="$HOME/data"
  export STEAM_ASAHI_NO_SPLASH=1

  data_directory="$XDG_DATA_HOME/steam-asahi"
  rootfs_directory="$XDG_DATA_HOME/fex-emu/RootFS"
  mkdir -p "$rootfs_directory"
  touch "$rootfs_directory/test.sqsh"

  ${lib.getExe package} 'steam://open/games?filter=ready to play'
  cp "$HOME/muvm-arguments" "$HOME/steam-arguments"

  test -f "$data_directory/bootstrap-installed"
  test -f "$data_directory/steam-launcher/bin_steam.sh"
  grep -Fx -- '--gpu-mode=drm' "$HOME/steam-arguments"
  grep -Fx -- '--mem=4096' "$HOME/steam-arguments"
  grep -Fx -- '--vram=2048' "$HOME/steam-arguments"
  test "$(grep -Fxc -- '--publish' "$HOME/steam-arguments")" = 2
  grep -Fx -- '27036/udp' "$HOME/steam-arguments"
  grep -Fx -- '27040/tcp' "$HOME/steam-arguments"
  grep -Fx -- '--interactive' "$HOME/steam-arguments"
  grep -F -- 'PATH=/run/wrappers/bin:' "$HOME/steam-arguments"
  grep -F -- '/bin/FEXBash' "$HOME/steam-arguments"
  grep -Fx -- '-cef-force-occlusion' "$HOME/steam-arguments"
  grep -Fx -- 'TEST_ENVIRONMENT=value with spaces' "$HOME/steam-arguments"
  grep -Fx -- \
    'steam://open/games?filter=ready to play' \
    "$HOME/steam-arguments"
  grep -F -- '-fex-steam.sh' "$HOME/steam-arguments"

  # A complete bootstrap is preserved on subsequent launches.
  printf '%s\n' preserved > "$data_directory/steam-launcher/bin_steam.sh"
  ${lib.getExe package}
  grep -Fx preserved "$data_directory/steam-launcher/bin_steam.sh"

  diagnostic_command='printf "%s\n" "hello world"'
  ${lib.getExe package} --fex "$diagnostic_command"
  grep -F -- '-fex-diagnostic.sh' "$HOME/muvm-arguments"
  grep -Fx -- "$diagnostic_command" "$HOME/muvm-arguments"
  test "$(grep -Fxc -- '--publish' "$HOME/muvm-arguments")" = 2
  grep -Fx -- '--vram=2048' "$HOME/muvm-arguments"

  # The diagnostic interface accepts one explicit shell program. Requiring the
  # caller to quote it avoids silently joining and reparsing an argv array.
  if ${lib.getExe package} --fex uname -m; then
    printf '%s\n' 'multi-argument diagnostic unexpectedly succeeded' >&2
    exit 1
  fi

  touch "$out"
''
