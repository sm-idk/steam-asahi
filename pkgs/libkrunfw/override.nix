{
  lib,
  upstream,
  fetchFromGitHub,
  fetchurl,
  nix-update-script,
}:
let
  libkrunfwOverrideVersion = "5.6.2";
  # Track fixes within libkrunfw's supported 6.12 LTS kernel series
  libkrunfwKernelVersion = "6.12.116";
  isCurrent = lib.versionAtLeast upstream.version libkrunfwOverrideVersion;
  overridden = upstream.overrideAttrs (
    finalAttrs: old: {
      version = libkrunfwOverrideVersion;
      src = fetchFromGitHub {
        owner = "libkrun";
        repo = "libkrunfw";
        tag = "v${finalAttrs.version}";
        hash = "sha256-HklZgZPjXe+eAGzRulEwRR1eo83tGlZBTRooCv0/ADU=";
      };
      kernelSrc = fetchurl {
        url = "mirror://kernel/linux/kernel/v6.x/linux-${libkrunfwKernelVersion}.tar.xz";
        hash = "sha256-yz7T391H5q3knckz2zNP2G4kyt7pINphLCYrDptqURs=";
      };
      makeFlags = (old.makeFlags or [ ]) ++ [ "KERNEL_VERSION=linux-${libkrunfwKernelVersion}" ];
      passthru = (old.passthru or { }) // {
        updateScript = nix-update-script {
          attrPath = "libkrunfw";
          extraArgs = [
            "--flake"
            "--system=aarch64-linux"
            "--override-filename=pkgs/libkrunfw/override.nix"
          ];
        };
      };
    }
  );
in
lib.warnIf isCurrent ''
  libkrunfw >= ${libkrunfwOverrideVersion} is now in nixpkgs; remove the libkrunfw override.
'' (if isCurrent then upstream else overridden)
