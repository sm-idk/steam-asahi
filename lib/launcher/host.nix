{
  lib,
  writeShellApplication,
  writeText,
  xdg-utils,
}:
{
  configuration,
  desktop,
  runtimeInputs,
  meta,
  nativeWayland ? true,
  portalResources ? false,
}:
let
  configFile = writeText "steam-asahi-launcher.json" (
    builtins.toJSON (
      configuration
      // {
        HOST_OPEN = lib.getExe' xdg-utils "xdg-open";
        GUEST_SESSION = lib.getExe desktop.session;
        DESKTOP_DIAGNOSTIC = lib.getExe desktop.diagnostic;
      }
      // lib.optionalAttrs nativeWayland {
        WAYPIPE = lib.getExe desktop.waypipe;
        WAYPIPE_ARGS = desktop.waypipeArgs;
      }
      // lib.optionalAttrs portalResources {
        PORTAL_RESOURCES = true;
      }
    )
  );
in
writeShellApplication {
  inherit runtimeInputs meta;
  inheritPath = false;
  name = "steam-asahi";
  text = ''
    exec ${lib.getExe desktop.python} -I ${desktop.source}/main.py ${configFile} "$@"
  '';
}
