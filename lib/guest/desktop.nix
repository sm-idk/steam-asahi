{
  lib,
  writeShellApplication,
  writeText,
  python315,
  libportal,
  muvm,
  waypipe,
  coreutils,
  util-linux,
  nativeWayland ? true,
  portalResources ? false,
  waypipeArgs ? [
    "--compress=none"
    "--threads=2"
  ],
}:
let
  source = (import ../../nix/sources.nix { inherit lib; }).launcher;
  python = python315.withPackages (packages: [
    packages.aiotools
    packages.anyio
    packages.boltons
    packages.jeepney
    packages.msgspec
    packages.pillow
    packages.psutil
    packages.pycapnp
    packages.pygobject3
    packages.tenacity
    packages.typing-extensions
  ]);
in
{
  inherit
    source
    python
    waypipe
    waypipeArgs
    ;
  opener = writeShellApplication {
    name = "steam-asahi-xdg-open";
    inheritPath = false;
    text = ''
      exec ${lib.getExe python} -I ${source}/desktop.py "$@"
    '';
  };
  session = writeShellApplication {
    name = "steam-asahi-session-init";
    inheritPath = false;
    runtimeEnv =
      lib.optionalAttrs nativeWayland {
        STEAM_ASAHI_WAYPIPE = lib.getExe waypipe;
        STEAM_ASAHI_KEEPER = lib.getExe' coreutils "sleep";
        STEAM_ASAHI_WAYPIPE_ARGS_FILE = writeText "waypipe-arguments.json" (builtins.toJSON waypipeArgs);
      }
      // lib.optionalAttrs portalResources {
        STEAM_ASAHI_PIPEWIRE_BRIDGE = lib.getExe' muvm "muvm-portal-pipewire";
      };
    text = ''
      exec ${lib.getExe python} -I ${source}/session.py
    '';
  };
  diagnostic = writeShellApplication {
    name = "steam-asahi-desktop-diagnostics";
    runtimeInputs = [
      coreutils
      util-linux
    ];
    inheritPath = true;
    text = ''
      exec ${lib.getExe python} -I ${source}/diagnostics.py "$@"
    '';
  };
  game = writeShellApplication {
    name = "steam-asahi-game";
    # The selected game and its runtime need their original guest search path
    inheritPath = true;
    text = ''
      export GI_TYPELIB_PATH="${libportal}/lib/girepository-1.0''${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
      exec ${lib.getExe python} -I ${source}/game.py "$@"
    '';
  };
}
