{ lib }:

{
  shellTests = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../src/launcher
      ../tests/shell/launcher/imports.py
      ../tests/shell/launcher/run.py
    ];
  };
}
