{
  lib,
  upstream,
  fetchPypi,
}:

upstream.override (previous: {
  packageOverrides = lib.composeExtensions (previous.packageOverrides or (_: _: { })) (
    _: pythonPrev:
      {
        # Python 3.15 adds platform tags to stable-ABI extension suffixes,
        # which pycairo's build needs
        meson-python = pythonPrev.meson-python.overridePythonAttrs (_: {
          doCheck = false;
        } // lib.optionalAttrs (lib.versionOlder pythonPrev.meson-python.version "0.22.1") {
          version = "0.22.1";
          src = fetchPypi {
            pname = "meson_python";
            version = "0.22.1";
            hash = "sha256-UsiGKLDlZxWS3CMGYT+19vNhX9JN7wWbmJTxQ7f5oTk=";
          };
        });
      }
      // lib.listToAttrs (
        map
          (name: {
            inherit name;
            value = pythonPrev.${name}.overridePythonAttrs (_: {
              doCheck = false;
              doInstallCheck = false;
              # Consumed by the setup hook at build time; jeepney's check
              # imports its optional trio backend and fails without trio
              pythonImportsCheck = [ ];
            });
          })
          [
            # Closure of lib/guest/desktop.nix and pkgs/steam/arm64/package.nix.
            # Building the shipped tools must not run library test suites or
            # pull their test-only inputs; nixpkgs' own CI exercises those
            # tests.
            "aiotools"
            "anyio"
            "async-lru"
            "boltons"
            "cffi"
            "cython"
            "filelock"
            "gevent"
            "hypothesis"
            "idna"
            "jeepney"
            "msgspec"
            "numpy"
            "pillow"
            "psutil"
            "pybind11"
            "pycapnp"
            "pycairo"
            "pygobject3"
            "sniffio"
            "tenacity"
            "typing-extensions"
            "vdf"
            "zope-event"
          ]
      )
  );
})
