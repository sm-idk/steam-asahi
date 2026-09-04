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
    muvmHostMount = "/tmp/steam-asahi-muvm-host";
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
  export XDG_RUNTIME_DIR="$HOME/runtime"
  export STEAM_ASAHI_NO_SPLASH=1

  data_directory="$XDG_DATA_HOME/steam-asahi"
  rootfs_directory="$XDG_DATA_HOME/fex-emu/RootFS"
  mkdir -p "$rootfs_directory"
  touch "$rootfs_directory/test.sqsh"

  ${lib.meta.getExe package} \
    'steam://open/games?filter=ready to play' \
    2>"$HOME/audio-warning"
  grep -F \
    "WARNING: PulseAudio socket not found at $XDG_RUNTIME_DIR/pulse/native." \
    "$HOME/audio-warning"
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
  fex_line=$(grep -Fn -- '/bin/FEXBash' "$HOME/steam-arguments" \
    | cut -d: -f1)
  test "$(sed -n "$((fex_line + 1))p" "$HOME/steam-arguments")" = \
    'exec /bin/bash "$@"'
  test "$(sed -n "$((fex_line + 2))p" "$HOME/steam-arguments")" = \
    steam-asahi-fex
  sed -n "$((fex_line + 3))p" "$HOME/steam-arguments" \
    | grep -F -- '-fex-steam.sh'
  grep -Fx -- '-cef-force-occlusion' "$HOME/steam-arguments"
  grep -Fx -- 'TEST_ENVIRONMENT=value with spaces' "$HOME/steam-arguments"
  grep -Fx -- \
    'steam://open/games?filter=ready to play' \
    "$HOME/steam-arguments"
  grep -F -- '-fex-steam.sh' "$HOME/steam-arguments"

  # A complete bootstrap is preserved on subsequent launches.
  printf '%s\n' preserved > "$data_directory/steam-launcher/bin_steam.sh"
  ${lib.meta.getExe package}
  grep -Fx preserved "$data_directory/steam-launcher/bin_steam.sh"

  diagnostic_command='printf "%s\n" "hello world"'
  ${lib.meta.getExe package} --fex "$diagnostic_command"
  grep -F -- '-fex-diagnostic.sh' "$HOME/muvm-arguments"
  fex_line=$(grep -Fn -- '/bin/FEXBash' "$HOME/muvm-arguments" \
    | cut -d: -f1)
  test "$(sed -n "$((fex_line + 1))p" "$HOME/muvm-arguments")" = \
    'exec /bin/bash "$@"'
  test "$(sed -n "$((fex_line + 2))p" "$HOME/muvm-arguments")" = \
    steam-asahi-fex
  sed -n "$((fex_line + 3))p" "$HOME/muvm-arguments" \
    | grep -F -- '-fex-diagnostic.sh'
  grep -Fx -- "$diagnostic_command" "$HOME/muvm-arguments"
  test "$(grep -Fxc -- '--publish' "$HOME/muvm-arguments")" = 2
  grep -Fx -- '--vram=2048' "$HOME/muvm-arguments"

  # The diagnostic interface accepts one explicit shell program. Requiring the
  # caller to quote it avoids silently joining and reparsing an argv array.
  if ${lib.meta.getExe package} --fex uname -m; then
    printf '%s\n' 'multi-argument diagnostic unexpectedly succeeded' >&2
    exit 1
  fi

  # Starting the host launcher from an existing muvm/FEX shell must fail
  # before it attempts nested virtualization.
  mkdir -p /tmp/steam-asahi-muvm-host
  if ${lib.meta.getExe package} 2>"$HOME/nested-muvm-error"; then
    printf '%s\n' 'nested muvm launch unexpectedly succeeded' >&2
    exit 1
  fi
  grep -Fx -- \
    'ERROR: Already inside a muvm guest. Exit FEXBash and run steam-asahi on the host.' \
    "$HOME/nested-muvm-error"

  touch "$out"
''
