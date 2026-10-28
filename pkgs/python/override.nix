{
  lib,
  upstream,
  fetchPypi,
  fetchFromGitHub,
  python314,
}:

upstream.override (previous: {
  packageOverrides = lib.composeExtensions (previous.packageOverrides or (_: _: { })) (
    _: pythonPrev: {
      # Match AnyIO's Python-version markers for its backport and loop tests
      anyio = pythonPrev.anyio.overridePythonAttrs (old: {
        nativeCheckInputs = lib.subtractLists [
          pythonPrev.exceptiongroup
          pythonPrev.uvloop
        ] old.nativeCheckInputs;
      });
      # Jedi's grammar discovery covers Python through 3.14
      jedi = pythonPrev.jedi.overridePythonAttrs (old: {
        nativeCheckInputs = (old.nativeCheckInputs or [ ]) ++ [ python314 ];
        patches = (old.patches or [ ]) ++ [ ./jedi/python315.patch ];
        # Trust the running interpreter and its virtualenv copies
        postPatch = (old.postPatch or "") + ''
          substituteInPlace jedi/api/environment.py \
            --replace-fail 'for environment in find_system_environments():' \
              'for environment in [SameEnvironment(), *find_system_environments()]:'
        '';
      });
      # Parso's post-release fixes handle Python 3.15 error messages
      parso = pythonPrev.parso.overridePythonAttrs (
        _:
        lib.optionalAttrs (lib.versionOlder pythonPrev.parso.version "0.8.8") {
          version = "0.8.7-unstable-2026-07-30";
          src = fetchFromGitHub {
            owner = "davidhalter";
            repo = "parso";
            rev = "512e78c1a8f4968086af652394a9cd0a91c16e54";
            hash = "sha256-8b/ZV3Ux+FLR/LhWwrs4rGQvQtUE6s3pSmXahytO6Gc=";
          };
        }
      );
      # Tornado's scaling checks use CPU time to tolerate busy CI workers
      tornado = pythonPrev.tornado.overridePythonAttrs (
        old:
        lib.optionalAttrs (lib.versionOlder pythonPrev.tornado.version "6.6.0rc1") {
          version = "6.6.0rc1";
          src = fetchFromGitHub {
            owner = "tornadoweb";
            repo = "tornado";
            tag = "v6.6.0rc1";
            hash = "sha256-lC83nhphcP0VK4Xi/5Tk5l/CBiuRADCvsiFPgwp3sX0=";
          };
          # Match upstream's runner, which silences HTTP access logs
          pytestFlags = (old.pytestFlags or [ ]) ++ [ "--log-disable=tornado.access" ];
        }
      );
      # Python 3.15 adds platform tags to stable-ABI extension suffixes
      meson-python = pythonPrev.meson-python.overridePythonAttrs (
        old:
        lib.optionalAttrs (lib.versionOlder pythonPrev.meson-python.version "0.22.1") {
          version = "0.22.1";
          src = fetchPypi {
            pname = "meson_python";
            version = "0.22.1";
            hash = "sha256-UsiGKLDlZxWS3CMGYT+19vNhX9JN7wWbmJTxQ7f5oTk=";
          };
          # The linker wrapper otherwise removes the /usr paths exercised by
          # the RPATH checks
          preCheck = (old.preCheck or "") + ''
            export NIX_ENFORCE_PURITY=0
          '';
        }
      );
    }
  );
})
