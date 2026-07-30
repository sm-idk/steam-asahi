{
  lib,
  runCommand,
  writeShellApplication,
  steam-asahi-arm64,
}:

let
  fakeMuvm = writeShellApplication {
    name = "muvm";
    text = ''
      : "''${TEST_MUVM_OUTPUT:?test output was not provided}"
      printf '%s\n' "$@" > "$TEST_MUVM_OUTPUT"
      printf '%s\n' "$HOME" > "$TEST_MUVM_OUTPUT.home"
      printf '%s\n' "$XDG_DATA_HOME" > "$TEST_MUVM_OUTPUT.data-home"
    '';
  };

  package = steam-asahi-arm64.override {
    muvm = fakeMuvm;
    customSteamHomeDir = "isolated ARM home";
    memoryMiB = 4096;
    vramMiB = 2048;
    publishPorts = [
      "27036/udp"
      "27040/tcp"
    ];
  };
in
runCommand "steam-asahi-arm64-launcher-test" { } ''
  export HOME="$TMPDIR/home with spaces"
  export XDG_DATA_HOME="$HOME/data"
  export XDG_CONFIG_HOME="$HOME/config"
  export XDG_RUNTIME_DIR="$HOME/runtime"
  export STEAM_ASAHI_NO_SPLASH=1
  export TEST_MUVM_OUTPUT="$TMPDIR/muvm-arguments"

  sourceHome="$HOME"
  sourceDataHome="$XDG_DATA_HOME"
  isolatedHome="$sourceDataHome/isolated ARM home"
  steamDirectory="$isolatedHome/.local/share/Steam"
  clientDirectory="$steamDirectory/steamrtarm64"
  protonDirectory="$steamDirectory/steamapps/common/Proton 11.0 (ARM64)"
  runtimeDirectory="$steamDirectory/steamapps/common/SteamLinuxRuntime_4-arm64"
  compatibilityDirectory="$steamDirectory/compatibilitytools.d/steam-asahi-proton-11-arm64"

  # Exercise repair of a partial bootstrap, not only the empty-directory case,
  # and import an x86 login without sharing any mutable Steam directories.
  mkdir -p \
    "$clientDirectory" \
    "$protonDirectory" \
    "$runtimeDirectory" \
    "$sourceDataHome/Steam/config" \
    "$sourceHome/.steam" \
    "$XDG_CONFIG_HOME/pulse"
  touch \
    "$clientDirectory/pre-existing-file" \
    "$protonDirectory/proton" \
    "$runtimeDirectory/_v2-entry-point"
  chmod +x "$protonDirectory/proton" "$runtimeDirectory/_v2-entry-point"
  printf '%s\n' local-login > "$sourceDataHome/Steam/local.vdf"
  printf '%s\n' users-login > "$sourceDataHome/Steam/config/loginusers.vdf"
  printf '%s\n' client-config > "$sourceDataHome/Steam/config/config.vdf"
  printf '%s\n' registry-login > "$sourceHome/.steam/registry.vdf"
  printf '%s\n' pulse-cookie > "$XDG_CONFIG_HOME/pulse/cookie"

  ${lib.getExe package} --import-login steam://open/games \
    2>"$HOME/audio-warning"
  grep -F \
    "WARNING: PulseAudio socket not found at $XDG_RUNTIME_DIR/pulse/native." \
    "$HOME/audio-warning"
  # A second launch must be idempotent, refresh the managed integration, and
  # repair an accidentally permissive copy of the host authentication cookie.
  chmod 0644 "$isolatedHome/.config/pulse/cookie"
  ${lib.getExe package} steam://open/games 2>>"$HOME/audio-warning"

  test "$(stat -c %a "$isolatedHome/.config/pulse/cookie")" = 600
  test -e "$clientDirectory/pre-existing-file"
  test -x "$clientDirectory/steam"
  test ! -d "$clientDirectory/steamrtarm64"
  test "$(cat "$steamDirectory/package/beta")" = publicbeta
  test "$(readlink "$isolatedHome/.steam/steam")" = "$steamDirectory"
  test "$(readlink "$isolatedHome/.steam/root")" = "$steamDirectory"
  test "$(readlink "$isolatedHome/.steam/sdkarm64")" = \
    "$steamDirectory/linuxarm64"
  grep -Fx local-login "$steamDirectory/local.vdf"
  grep -Fx users-login "$steamDirectory/config/loginusers.vdf"
  grep -Fx client-config "$steamDirectory/config/config.vdf"
  grep -Fx registry-login "$isolatedHome/.steam/registry.vdf"
  grep -Fx pulse-cookie "$isolatedHome/.config/pulse/cookie"
  grep -Fx local-login "$sourceDataHome/Steam/local.vdf"

  test -x "$compatibilityDirectory/run-proton"
  test -x "$compatibilityDirectory/steam-asahi-proton"
  test -L "$compatibilityDirectory/proton"
  test -L "$compatibilityDirectory/runtime"
  test -L "$compatibilityDirectory/host-libs"
  grep -F '"proton_11_arm64"' "$compatibilityDirectory/compatibilitytool.vdf"
  grep -F '"display_name" "Proton 11.0 (ARM64)"' "$compatibilityDirectory/compatibilitytool.vdf"
  grep -F '"commandline" "/steam-asahi-proton %verb%"' "$compatibilityDirectory/toolmanifest.vdf"

  grep -Fx "$isolatedHome" "$TEST_MUVM_OUTPUT.home"
  grep -Fx "$isolatedHome/.local/share" "$TEST_MUVM_OUTPUT.data-home"
  grep -Fx -- '--gpu-mode=drm' "$TEST_MUVM_OUTPUT"
  grep -Fx -- '--mem=4096' "$TEST_MUVM_OUTPUT"
  grep -Fx -- '--vram=2048' "$TEST_MUVM_OUTPUT"
  test "$(grep -Fxc -- '--publish' "$TEST_MUVM_OUTPUT")" = 2
  grep -Fx -- '27036/udp' "$TEST_MUVM_OUTPUT"
  grep -Fx -- '27040/tcp' "$TEST_MUVM_OUTPUT"
  grep -Fx -- '--interactive' "$TEST_MUVM_OUTPUT"
  grep -Fx -- '--steam' "$TEST_MUVM_OUTPUT"
  grep -Fx -- '-cef-force-occlusion' "$TEST_MUVM_OUTPUT"
  grep -Fx -- 'steam://open/games' "$TEST_MUVM_OUTPUT"

  touch "$out"
''
