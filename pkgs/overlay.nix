final: prev:

(import ./default.nix { pkgs = final; })
// {
  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (_: pythonPrev: {
      boltons = pythonPrev.boltons.overridePythonAttrs (_: {
        version = "26.2.0";
        src = final.fetchPypi {
          pname = "boltons";
          version = "26.2.0";
          hash = "sha256-05z9FcGhw71NcFyCJS+p7bjk9ejMA5+OOa+sextH6Sw=";
        };
        # This release includes nixpkgs' pytest 9 compatibility fix
        patches = [ ];
      });
      msgspec = pythonPrev.msgspec.overridePythonAttrs (_: {
        version = "0.22.0";
        src = final.fetchPypi {
          pname = "msgspec";
          version = "0.22.0";
          hash = "sha256-ChNiSklpFZ/jXYwqPTd7K2G72FheMnRA1eUnJa/8zjg=";
        };
        # This release includes nixpkgs' Ext.code fix for big-endian hosts
        patches = [ ];
      });
    })
  ];
  # Import override expressions directly so the upstream .override API survives
  fex = import ./fex/override.nix {
    inherit (final) lib;
    upstream = prev.fex;
  };
  libkrun = import ./libkrun/override.nix {
    inherit (final) lib fetchFromGitHub rustPlatform;
    upstream = prev.libkrun;
  };
  libkrunfw = import ./libkrunfw/override.nix {
    inherit (final) lib fetchFromGitHub fetchurl;
    upstream = prev.libkrunfw;
  };
  muvm = import ./muvm/override.nix {
    inherit (final) fetchFromGitHub rustPlatform;
    upstream = prev.muvm;
  };
}
