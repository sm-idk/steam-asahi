{
  lib,
  bash,
  writeShellApplication,
  writeTextFile,
  runtimeShell,
  shellcheck-minimal,
}:

assert lib.asserts.assertMsg (lib.versionAtLeast bash.version "5.3")
  "steam-asahi: Bash >= 5.3 is required";

let
  renderShell =
    configuration: source:
    lib.concatStringsSep "\n" [
      (import ./common.nix { inherit lib; })
      (import source { inherit lib configuration; })
    ];
  sourceApplication =
    name: source:
    writeShellApplication {
      inherit name;
      text = renderShell { } source;
    };
in
{
  inherit renderShell sourceApplication;

  # FEX explicitly passes these checked scripts to the rootfs's x86 Bash
  renderSource = name: source: lib.getExe (sourceApplication name source);

  application =
    {
      source,
      configuration ? { },
      ...
    }@arguments:
    writeShellApplication (
      removeAttrs arguments [
        "source"
        "configuration"
      ]
      // {
        inheritPath = false;
        text = renderShell configuration source;
      }
    );

  # Copied Proton tools execute inside Pressure Vessel, where /bin/sh and the
  # runtime's commands must work before Nix libraries can be added to the path
  posix =
    { name, text }:
    writeTextFile {
      inherit name;
      executable = true;
      text = "#!/bin/sh\n" + text;
      checkPhase = ''
        ${runtimeShell} -n "$target"
        ${lib.getExe shellcheck-minimal} --shell=sh "$target"
      '';
    };
}
