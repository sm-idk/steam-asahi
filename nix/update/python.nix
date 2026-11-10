{
  lib,
  python3,
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
    inherit (python3.pkgs)
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
    pygobject = python3.pkgs.pygobject3;
    inherit ruff ty;
  };
  metadata = writeText "python-dependency-versions.json" (
    builtins.toJSON {
      versions = lib.mapAttrs (_: package: package.version) packages;
      python = lib.getExe python3;
      pythonVersion = python3.version;
      pythonMinor = lib.versions.majorMinor python3.version;
      # Tenacity is Git-sourced because Nix's tag is not available on PyPI
      gitSources.tenacity = {
        git = packages.tenacity.src.gitRepoUrl;
        rev = packages.tenacity.src.rev;
      };
    }
  );
  python = python3.withPackages (ps: [
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
