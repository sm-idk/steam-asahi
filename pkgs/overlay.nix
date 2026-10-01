final: prev:
let
  fexOverrideVersion = "2609";
  libkrunOverrideVersion = "1.19.6";
  libkrunfwOverrideVersion = "5.6.2";
  nixpkgsFexIsCurrent = prev.lib.strings.versionAtLeast prev.fex.version fexOverrideVersion;
  nixpkgsLibkrunIsCurrent = prev.lib.strings.versionAtLeast prev.libkrun.version libkrunOverrideVersion;
  nixpkgsLibkrunfwIsCurrent = prev.lib.strings.versionAtLeast prev.libkrunfw.version libkrunfwOverrideVersion;
  overriddenFex = prev.fex.overrideAttrs (old: {
    version = fexOverrideVersion;
    src = old.src.overrideAttrs (_: {
      rev = "refs/tags/FEX-${fexOverrideVersion}";
      hash = "sha256-L6dy8FBT/4mHBKq/nifdYREIb6C/eG8Ph6FP9ET4Syc=";
    });
    doCheck = false;
  });
  overriddenLibkrun = prev.libkrun.overrideAttrs (
    finalAttrs: _old: {
      version = libkrunOverrideVersion;
      src = prev.fetchFromGitHub {
        owner = "libkrun";
        repo = "libkrun";
        tag = "v${finalAttrs.version}";
        hash = "sha256-h37J1J/oe4PpY5Xtv8Js/wEA7av9M/VK4OTY1svK++0=";
      };
      cargoDeps = prev.rustPlatform.fetchCargoVendor {
        inherit (finalAttrs) src;
        hash = "sha256-SPlozqdmX0khawoFjZrqYjQ5qDY4tSVa7gpehYHUTz8=";
      };
    }
  );
  overriddenLibkrunfw = prev.libkrunfw.overrideAttrs (
    finalAttrs: _old: {
      version = libkrunfwOverrideVersion;
      src = prev.fetchFromGitHub {
        owner = "libkrun";
        repo = "libkrunfw";
        tag = "v${finalAttrs.version}";
        hash = "sha256-HklZgZPjXe+eAGzRulEwRR1eo83tGlZBTRooCv0/ADU=";
      };
      kernelSrc = prev.fetchurl {
        url = "mirror://kernel/linux/kernel/v6.x/linux-6.12.109.tar.xz";
        hash = "sha256-VITlUqM04VAZ9K66ieW1jwRlHPL04k4E3p8VLxw44/o=";
      };
    }
  );
in
{
  steam-arm64-client = final.callPackage ./steam-arm64-client { };
  steam-asahi-arm64 = final.callPackage ./steam-asahi-arm64 { };
  steam-asahi = final.callPackage ./steam-asahi { };

  libkrun = prev.lib.trivial.warnIf nixpkgsLibkrunIsCurrent ''
    libkrun >= ${libkrunOverrideVersion} is now in nixpkgs; remove the libkrun override.
  '' (if nixpkgsLibkrunIsCurrent then prev.libkrun else overriddenLibkrun);
  libkrunfw = prev.lib.trivial.warnIf nixpkgsLibkrunfwIsCurrent ''
    libkrunfw >= ${libkrunfwOverrideVersion} is now in nixpkgs; remove the libkrunfw override.
  '' (if nixpkgsLibkrunfwIsCurrent then prev.libkrunfw else overriddenLibkrunfw);

  fex = prev.lib.trivial.warnIf nixpkgsFexIsCurrent ''
    FEX >= ${fexOverrideVersion} is now in nixpkgs; remove the FEX override.
  '' (if nixpkgsFexIsCurrent then prev.fex else overriddenFex);
  # Separate VM control sockets while retaining host audio and desktop paths
  muvm = prev.muvm.overrideAttrs (
    finalAttrs: old: {
      version = "0.7.0-unstable-2026-09-25";
      src = prev.fetchFromGitHub {
        owner = "AsahiLinux";
        repo = "muvm";
        rev = "b761e07b84652e7fb00df83315907c1809899080";
        hash = "sha256-I6MtpnVA1+BvDXzEjP+bCP5w+t8JgOH5oRHuIGwyOys=";
      };
      cargoHash = null;
      cargoDeps = prev.rustPlatform.fetchCargoVendor {
        inherit (finalAttrs) src;
        hash = "sha256-HDHo/NfQM16JU9DbblFw2jxPEhhgdE/EUgBriKg/6uM=";
      };
      patches = (old.patches or [ ]) ++ [ ./muvm/runtime-directory.patch ];
    }
  );
}
