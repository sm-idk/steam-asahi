final: prev:

(import ./default.nix { pkgs = final; })
// {
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
