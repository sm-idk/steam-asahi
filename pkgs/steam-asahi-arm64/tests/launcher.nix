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
      printf '%s\n' "$@" > "$HOME/muvm-arguments"
    '';
  };

  package = steam-asahi-arm64.override {
    muvm = fakeMuvm;
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
  export XDG_RUNTIME_DIR="$HOME/runtime"
  export STEAM_ASAHI_NO_SPLASH=1

  steamDirectory="$XDG_DATA_HOME/Steam"
  clientDirectory="$steamDirectory/steamrtarm64"
  protonDirectory="$steamDirectory/steamapps/common/Proton 11.0 (ARM64)"
  runtimeDirectory="$steamDirectory/steamapps/common/SteamLinuxRuntime_4-arm64"
  compatibilityDirectory="$steamDirectory/compatibilitytools.d/steam-asahi-proton-11-arm64"

  # Exercise repair of a partial bootstrap, not only the empty-directory case.
  mkdir -p "$clientDirectory" "$protonDirectory" "$runtimeDirectory"
  touch "$clientDirectory/pre-existing-file" "$protonDirectory/proton" "$runtimeDirectory/_v2-entry-point"
  chmod +x "$protonDirectory/proton" "$runtimeDirectory/_v2-entry-point"

  ${lib.getExe package} steam://open/games 2>"$HOME/audio-warning"
  grep -F \
    "WARNING: PulseAudio socket not found at $XDG_RUNTIME_DIR/pulse/native." \
    "$HOME/audio-warning"
  # A second launch must be idempotent and refresh the managed integration.
  ${lib.getExe package} steam://open/games 2>>"$HOME/audio-warning"

  test -e "$clientDirectory/pre-existing-file"
  test -x "$clientDirectory/steam"
  test ! -d "$clientDirectory/steamrtarm64"
  test "$(cat "$steamDirectory/package/beta")" = publicbeta
  test "$(readlink "$HOME/.steam/steam")" = "$steamDirectory"
  test "$(readlink "$HOME/.steam/root")" = "$steamDirectory"
  test "$(readlink "$HOME/.steam/sdkarm64")" = "$steamDirectory/linuxarm64"

  test -x "$compatibilityDirectory/run-proton"
  test -x "$compatibilityDirectory/steam-asahi-proton"
  test -L "$compatibilityDirectory/proton"
  test -L "$compatibilityDirectory/runtime"
  test -L "$compatibilityDirectory/host-libs"
  grep -F '"proton_11_arm64"' "$compatibilityDirectory/compatibilitytool.vdf"
  grep -F '"display_name" "Proton 11.0 (ARM64)"' "$compatibilityDirectory/compatibilitytool.vdf"
  grep -F '"commandline" "/steam-asahi-proton %verb%"' "$compatibilityDirectory/toolmanifest.vdf"

  grep -Fx -- '--gpu-mode=drm' "$HOME/muvm-arguments"
  grep -Fx -- '--mem=4096' "$HOME/muvm-arguments"
  grep -Fx -- '--vram=2048' "$HOME/muvm-arguments"
  test "$(grep -Fxc -- '--publish' "$HOME/muvm-arguments")" = 2
  grep -Fx -- '27036/udp' "$HOME/muvm-arguments"
  grep -Fx -- '27040/tcp' "$HOME/muvm-arguments"
  grep -Fx -- '--interactive' "$HOME/muvm-arguments"
  grep -Fx -- '--steam' "$HOME/muvm-arguments"
  grep -Fx -- '-cef-force-occlusion' "$HOME/muvm-arguments"
  grep -Fx -- 'steam://open/games' "$HOME/muvm-arguments"

  touch "$out"
''
