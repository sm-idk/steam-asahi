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
  python = python314.withPackages (packages: [
    packages.boltons
    packages.msgspec
  ]);
  configFile = writeText "steam-asahi-launcher.json" (builtins.toJSON configuration);
in
writeShellApplication {
  inherit runtimeInputs meta;
  inheritPath = false;
  name = "steam-asahi";
  text = ''
    exec ${lib.meta.getExe python} -I ${../../src/launcher}/main.py ${configFile} "$@"
  '';
}
