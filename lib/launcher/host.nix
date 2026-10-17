{
  lib,
  writeShellApplication,
  writeText,
  python315,
}:
{
  configuration,
  runtimeInputs,
  meta,
}:
let
  python = python315.withPackages (packages: [
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
