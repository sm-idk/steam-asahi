final: prev:

(import ./default.nix { pkgs = final; })
// {
  python315 = prev.python315.override (previous: {
    packageOverrides = final.lib.composeExtensions (previous.packageOverrides or (_: _: { })) (
      _: pythonPrev: {
        # AnyIO's test-only exceptiongroup dependency asserts pre-3.15 wording
        anyio = pythonPrev.anyio.overridePythonAttrs (_: {
          doCheck = false;
        });
        # Trio's test closure pulls a parser without Python 3.15 grammar support
        # Steam uses Jeepney's asyncio backend, not its optional Trio backend
        jeepney = pythonPrev.jeepney.overridePythonAttrs (old: {
          doCheck = false;
          pythonImportsCheck = final.lib.remove "jeepney.io.trio" old.pythonImportsCheck;
        });
        # Do not build NumPy/Boost, gevent, or Sphinx/mypy just for library tests
        pybind11 = (pythonPrev.pybind11.override { buildTests = false; }).overridePythonAttrs (_: {
          doCheck = false;
        });
        pillow = pythonPrev.pillow.overridePythonAttrs (_: {
          doCheck = false;
        });
        psutil = pythonPrev.psutil.overridePythonAttrs (_: {
          doCheck = false;
        });
        tenacity = pythonPrev.tenacity.overridePythonAttrs (_: {
          doCheck = false;
        });
      }
    );
  });
  # Import override expressions directly so the upstream .override API survives
  fex = import ./fex/override.nix {
    inherit (final) lib nix-update-script;
    upstream = prev.fex;
  };
  libkrun = import ./libkrun/override.nix {
    inherit (final)
      lib
      fetchFromGitHub
      rustPlatform
      nix-update-script
      ;
    upstream = prev.libkrun;
  };
  libkrunfw = import ./libkrunfw/override.nix {
    inherit (final)
      lib
      fetchFromGitHub
      fetchurl
      nix-update-script
      ;
    upstream = prev.libkrunfw;
  };
  muvm = import ./muvm/override.nix {
    upstream = prev.muvm;
  };
  waypipe = import ./waypipe/override.nix {
    inherit (final)
      ffmpeg
      ffmpeg_8
      python3
      rustfmt
      wayland-protocols
      ;
    upstream = prev.waypipe;
  };
}
