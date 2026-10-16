{
  lib,
  writeShellApplication,
  writeText,
  python314,
}:
{
  configuration,
  runtimeInputs,
  meta,
}:
let
  # Repaired game shortcuts run this command, so the launcher's own name has
  # to stay in step with the executable
  launcherName = "steam-asahi";
  python = python314.withPackages (packages: [
    packages.boltons
    packages.msgspec
  ]);
  configFile = writeText "steam-asahi-launcher.json" (
    builtins.toJSON (configuration // { LAUNCHER_COMMAND = launcherName; })
  );
in
writeShellApplication {
  inherit runtimeInputs meta;
  inheritPath = false;
  name = launcherName;
  text = ''
    exec ${lib.meta.getExe python} -I ${../../src/launcher}/main.py ${configFile} "$@"
  '';
}
