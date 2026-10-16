{
  lib,
  runCommand,
  unzip,
  writeShellApplication,
  steam-asahi,
  steam-x86_64-client,
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

  fakeSteamSource =
    runCommand "fake-steam-x86_64-client"
      {
        version = "test";
        passthru.updateChannel = "publicbeta";
      }
      ''
        mkdir -p "$out/share/steam-x86_64-client/steamrt64"
        printf '%s\n' '#!/bin/sh' 'exit 0' \
          > "$out/share/steam-x86_64-client/steamrt64/steam"
        chmod +x "$out/share/steam-x86_64-client/steamrt64/steam"
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
    steam-x86_64-client = fakeSteamSource;
    muvmHostMount = "/tmp/steam-asahi-muvm-host";
    cpuList = [
      0
      1
      4
      5
    ];
    memoryMiB = 4096;
    vramMiB = 2048;
    publishPorts = [
      "27036/udp"
      "27040/tcp"
    ];
    extraEnv.TEST_ENVIRONMENT = "value with spaces";
  };
in
runCommand "steam-asahi-launcher-test" { nativeBuildInputs = [ unzip ]; } ''
  export HOME="$TMPDIR/home with spaces"
  export XDG_CONFIG_HOME="$HOME/config"
  export XDG_DATA_HOME="$HOME/data"
  export XDG_RUNTIME_DIR="$HOME/runtime"
  export STEAM_ASAHI_NO_SPLASH=1

  steam_directory="$XDG_DATA_HOME/Steam"
  client="$steam_directory/steamrt64/steam"
  rootfs_directory="$XDG_DATA_HOME/fex-emu/RootFS"
  mkdir -p "$rootfs_directory"
  touch "$rootfs_directory/test.sqsh"
  mkdir -p "$steam_directory"
  touch "$steam_directory/.steam-disable-steamrt64-client"
  touch "$steam_directory/.steam-enable-steamrt64-client"

  ${lib.meta.getExe package} \
    'steam://open/games?filter=ready to play' \
    2>"$HOME/audio-warning"
  grep -F \
    "WARNING: PulseAudio socket not found at $XDG_RUNTIME_DIR/pulse/native." \
    "$HOME/audio-warning"
  cp "$HOME/muvm-arguments" "$HOME/steam-arguments"

  test -x "$client"
  test ! -e "$steam_directory/.steam-disable-steamrt64-client"
  test ! -e "$steam_directory/.steam-enable-steamrt64-client"
  grep -Fx publicbeta "$steam_directory/package/beta"
  test "$(readlink "$HOME/.steam/root")" = "$steam_directory"
  test "$(readlink "$HOME/.steam/steam")" = "$steam_directory"
  grep -Fx "$client" "$HOME/steam-arguments"
  test ! -e "$XDG_DATA_HOME/steam-asahi/steam-launcher"
  test ! -e "$steam_directory/ubuntu12_32/steam"
  grep -Fx -- '--gpu-mode=drm' "$HOME/steam-arguments"
  grep -Fx -- '--cpu-list=0,1,4,5' "$HOME/steam-arguments"
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

  # Preserve self-updates while restoring the selected beta channel
  printf '%s\n' preserved > "$client"
  printf '%s\n' public > "$steam_directory/package/beta"
  ${lib.meta.getExe package}
  grep -Fx preserved "$client"
  grep -Fx publicbeta "$steam_directory/package/beta"

  # Reuse an existing Steam installation outside XDG_DATA_HOME
  relocated="$HOME/existing Steam library"
  mv "$steam_directory" "$relocated"
  ln -sfn "$relocated" "$HOME/.steam/steam"
  ln -sfn "$relocated" "$HOME/.steam/root"
  ${lib.meta.getExe package}
  grep -Fx "$relocated/steamrt64/steam" "$HOME/muvm-arguments"
  grep -Fx preserved "$relocated/steamrt64/steam"
  test ! -e "$steam_directory"

  # The real bootstrap is an unpatched x86_64 ELF, suitable for FEX
  client=${steam-x86_64-client}/share/steam-x86_64-client/steamrt64/steam
  test -x "$client"
  test "$(od -An -tx1 -j4 -N1 "$client" | tr -d ' ')" = 02
  test "$(od -An -tx1 -j18 -N2 "$client" | tr -d ' ')" = 3e00
  test "$(sha256sum "$client" | cut -d' ' -f1)" = \
    "$(unzip -p ${steam-x86_64-client.src} steamrt64/steam | sha256sum | cut -d' ' -f1)"

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
  grep -Fx -- '--cpu-list=0,1,4,5' "$HOME/muvm-arguments"
  grep -Fx -- '--vram=2048' "$HOME/muvm-arguments"

  # Honor FEX's nested JSON configuration even without a local rootfs image
  rm "$rootfs_directory/test.sqsh"
  mkdir -p "$XDG_CONFIG_HOME/fex-emu"
  printf '%s\n' '{"Config":{"RootFS":"/external/rootfs.sqsh"}}' \
    > "$XDG_CONFIG_HOME/fex-emu/Config.json"
  ${lib.meta.getExe package} --fex "$diagnostic_command"
  grep -Fx -- "$diagnostic_command" "$HOME/muvm-arguments"

  # Text resembling RootFS in malformed JSON must trigger the fetcher
  printf '%s\n' 'invalid {"RootFS":"/external/rootfs.sqsh"}' \
    > "$XDG_CONFIG_HOME/fex-emu/Config.json"
  if ${lib.meta.getExe package} --fex "$diagnostic_command" \
    2>"$HOME/rootfs-error"; then
    printf '%s\n' 'malformed FEX configuration unexpectedly succeeded' >&2
    exit 1
  fi
  grep -Fx -- 'unexpected FEX rootfs fetch' "$HOME/rootfs-error"
  printf '%s\n' '{"Config":{"RootFS":"/external/rootfs.sqsh"}}' \
    > "$XDG_CONFIG_HOME/fex-emu/Config.json"

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
