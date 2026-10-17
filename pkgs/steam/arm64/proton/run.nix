{ lib }:
let
  overrides = "/usr/lib/pressure-vessel/overrides/lib";
  libraryPath = lib.concatStringsSep ":" [
    "${overrides}/aarch64-linux-gnu"
    overrides
  ];
in
''
  # shellcheck shell=sh
  #
  # Runs Proton with the host libraries imported into Pressure Vessel

  script_path=$(readlink --canonicalize -- "$0")
  tool_directory=''${script_path%/*}
  readonly script_path tool_directory

  library_path="''${tool_directory}/host-libs":${lib.escapeShellArg libraryPath}
  readonly library_path
  export LD_LIBRARY_PATH="''${library_path}''${LD_LIBRARY_PATH:+:''${LD_LIBRARY_PATH}}"

  exec python3 "''${tool_directory}/proton/proton" "$@"
''
