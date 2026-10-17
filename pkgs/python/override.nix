{
  lib,
  upstream,
  fetchPypi,
  fetchFromGitHub,
  tzdata,
}:

upstream.override (previous: {
  packageOverrides = lib.composeExtensions (previous.packageOverrides or (_: _: { })) (
    _: pythonPrev: {
      # pycapnp's build tooling needs time-machine with Python 3.15 support
      time-machine = pythonPrev.time-machine.overridePythonAttrs (
        _:
        lib.optionalAttrs (lib.versionOlder pythonPrev.time-machine.version "3.5.1") {
          version = "3.5.1";
          src = fetchFromGitHub {
            owner = "adamchainz";
            repo = "time-machine";
            tag = "3.5.1";
            hash = "sha256-k/URZJz/kiPg20SYoOblaleIWdB8coaT/nHLAV7dDU0=";
          };
          TZDIR = "${tzdata}/share/zoneinfo";
        }
      );
      boltons = pythonPrev.boltons.overridePythonAttrs (
        _:
        lib.optionalAttrs (lib.versionOlder pythonPrev.boltons.version "26.2.0") {
          version = "26.2.0";
          src = fetchPypi {
            pname = "boltons";
            version = "26.2.0";
            hash = "sha256-05z9FcGhw71NcFyCJS+p7bjk9ejMA5+OOa+sextH6Sw=";
          };
          # This release includes nixpkgs' pytest 9 compatibility fix
          patches = [ ];
        }
      );
      msgspec = pythonPrev.msgspec.overridePythonAttrs (
        _:
        lib.optionalAttrs (lib.versionOlder pythonPrev.msgspec.version "0.22.0") {
          version = "0.22.0";
          src = fetchPypi {
            pname = "msgspec";
            version = "0.22.0";
            hash = "sha256-ChNiSklpFZ/jXYwqPTd7K2G72FheMnRA1eUnJa/8zjg=";
          };
          # This release includes nixpkgs' Ext.code fix for big-endian hosts
          patches = [ ];
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
