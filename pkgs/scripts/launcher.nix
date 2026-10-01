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
  configFile = writeText "steam-asahi-launcher.json" (builtins.toJSON configuration);
in
writeShellApplication {
  inherit runtimeInputs meta;
  inheritPath = false;
  name = "steam-asahi";
  text = ''
    exec ${lib.meta.getExe python314} -I ${./launcher}/main.py ${configFile} "$@"
  '';
}
