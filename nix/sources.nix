{ lib }:

let
  shellFiles = lib.fileset.unions [
    (lib.fileset.fileFilter (file: file.hasExt "sh") ../pkgs)
    ../src/guest
    (lib.fileset.fileFilter (file: file.hasExt "sh") ../tests)
    ../pkgs/steam/arm64/proton/run
    ../pkgs/steam/arm64/proton/wrapper
  ];
in
{
  shell = lib.fileset.toSource {
    root = ../.;
    fileset = shellFiles;
  };
  shellTests = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      shellFiles
      ../src/launcher
      ../tests/shell/launcher/imports.py
      ../tests/shell/launcher/run.py
    ];
  };
}
