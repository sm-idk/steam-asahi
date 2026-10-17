{ lib }:

let
  launcherFiles = lib.fileset.fileFilter (
    file: file.hasExt "py" || file.hasExt "capnp"
  ) ../src/launcher;
in
{
  launcher = lib.fileset.toSource {
    root = ../src/launcher;
    fileset = launcherFiles;
  };

  shellTests = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      launcherFiles
      ../tests/shell/launcher/imports.py
      ../tests/shell/launcher/run.py
    ];
  };
}
