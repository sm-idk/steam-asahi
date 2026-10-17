{
  lib,
  upstream,
  fetchFromGitHub,
  rustPlatform,
  nix-update-script,
}:
let
  libkrunOverrideVersion = "1.19.6";
  isCurrent = lib.versionAtLeast upstream.version libkrunOverrideVersion;
  overridden = upstream.overrideAttrs (
    finalAttrs: old: {
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
      passthru = (old.passthru or { }) // {
        updateScript = nix-update-script {
          attrPath = "libkrun";
          extraArgs = [
            "--flake"
            "--system=aarch64-linux"
            "--override-filename=pkgs/libkrun/override.nix"
          ];
        };
      };
    }
  );

in
(lib.warnIf isCurrent ''
  libkrun >= ${libkrunOverrideVersion} is now in nixpkgs; its version pin can be removed while retaining the portal transport patch.
'' (if isCurrent then upstream else overridden)).overrideAttrs
  (old: {
    patches = (old.patches or [ ]) ++ [ ./portal-remotes.patch ];
    postPatch = (old.postPatch or "") + ''
      cp ${./portal_registry.rs} src/rutabaga_gfx/src/cross_domain/portal_registry.rs
      cp ${../../lib/transport/unix_stream.rs} src/rutabaga_gfx/src/cross_domain/sys/unix_stream.rs
    '';
  })
