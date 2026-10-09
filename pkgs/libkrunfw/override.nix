{
  lib,
  upstream,
  fetchFromGitHub,
  fetchurl,
}:
let
  libkrunfwOverrideVersion = "5.6.2";
  libkrunfwKernelVersion = "6.12.112";
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
        hash = "sha256-Fk3J0fbJPGGhXh8HHEg3m0Z/KxfEacznIjRxloII7QM=";
      };
      makeFlags = (old.makeFlags or [ ]) ++ [ "KERNEL_VERSION=linux-${libkrunfwKernelVersion}" ];
    }
  );
in
lib.warnIf isCurrent ''
  libkrunfw >= ${libkrunfwOverrideVersion} is now in nixpkgs; remove the libkrunfw override.
'' (if isCurrent then upstream else overridden)
