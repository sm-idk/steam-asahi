{ pkgs }:

let
  # Inject project builders locally and resolve packages from the final overlay
  builders = {
    launcherOptions = import ../lib/launcher/options.nix { inherit (pkgs) lib; };
    launcherEnvironments = import ../lib/launcher/environments.nix;
    guestScripts = pkgs.callPackage ../lib/guest/scripts.nix { };
    mkHostLauncher = pkgs.callPackage ../lib/launcher/host.nix { };
    mkLauncherPackage = pkgs.callPackage ../lib/launcher/package.nix { };
  };
  callPackage = pkgs.lib.callPackageWith (pkgs // builders);
in
{
  steam-arm64-client = callPackage ./steam/client/package.nix { };
  steam-asahi = callPackage ./steam/fex/package.nix { };
  steam-asahi-arm64 = callPackage ./steam/arm64/package.nix { };
}
