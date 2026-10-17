final: prev:

(import ./default.nix { pkgs = final; })
// {
  # Keep launcher compatibility updates within the Python 3.15 package set
  python315 = import ./python/override.nix {
    inherit (final)
      lib
      fetchPypi
      fetchFromGitHub
      tzdata
      ;
    upstream = prev.python315;
  };
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
