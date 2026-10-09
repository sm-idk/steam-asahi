{
  lib,
  upstream,
  fetchFromGitHub,
  rustPlatform,
}:
let
  libkrunOverrideVersion = "1.19.6";
  isCurrent = lib.versionAtLeast upstream.version libkrunOverrideVersion;
  overridden = upstream.overrideAttrs (
    finalAttrs: _old: {
      version = libkrunOverrideVersion;
      src = fetchFromGitHub {
        owner = "libkrun";
        repo = "libkrun";
        tag = "v${finalAttrs.version}";
        hash = "sha256-h37J1J/oe4PpY5Xtv8Js/wEA7av9M/VK4OTY1svK++0=";
      };
      cargoDeps = rustPlatform.fetchCargoVendor {
        inherit (finalAttrs) src;
        hash = "sha256-SPlozqdmX0khawoFjZrqYjQ5qDY4tSVa7gpehYHUTz8=";
      };
    }
  );

in
lib.warnIf isCurrent ''
  libkrun >= ${libkrunOverrideVersion} is now in nixpkgs; remove the libkrun override.
'' (if isCurrent then upstream else overridden)
