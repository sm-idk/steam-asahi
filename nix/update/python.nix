{
  lib,
  python315,
  ruff,
  ty,
  uv,
  git,
  writeShellApplication,
  writeText,
}:
let
  # These are distribution names, not necessarily Nix attribute names
  packages = {
    inherit (python315.pkgs)
      aiotools
      anyio
      async-lru
      boltons
      idna
      jeepney
      msgspec
      packaging
      pillow
      psutil
      pycairo
      pycapnp
      tenacity
      tomlkit
      typing-extensions
      vdf
      ;
    pygobject = python315.pkgs.pygobject3;
    inherit ruff ty;
  };
  metadata = writeText "python-dependency-versions.json" (
    builtins.toJSON {
      versions = lib.mapAttrs (_: package: package.version) packages;
      python = lib.getExe python315;
      pythonVersion = python315.version;
      pythonMinor = lib.versions.majorMinor python315.version;
      # Tenacity is Git-sourced because Nix's tag is not available on PyPI
      gitSources.tenacity = {
        git = packages.tenacity.src.gitRepoUrl;
        rev = packages.tenacity.src.rev;
      };
    }
  );
  python = python315.withPackages (ps: [
    ps.packaging
    ps.tomlkit
  ]);
in
writeShellApplication {
  name = "update-python-deps";
  inheritPath = false;
  runtimeInputs = [
    git
    uv
  ];
  text = ''
    exec ${lib.getExe python} ${./python.py} ${metadata} "$@"
  '';
}
