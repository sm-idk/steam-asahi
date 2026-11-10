{
  lib,
  upstream,
  fetchFromGitHub,
  rustPlatform,
  nix-update-script,
}:
let
  libkrunOverrideVersion = "1.19.8";
  isCurrent = lib.versionAtLeast upstream.version libkrunOverrideVersion;
  overridden = upstream.overrideAttrs (
    finalAttrs: old: {
      version = libkrunOverrideVersion;
      src = fetchFromGitHub {
        owner = "libkrun";
        repo = "libkrun";
        tag = "v${finalAttrs.version}";
        hash = "sha256-JcMkgtoNlY2cK32ZjlyGCne2gIWXTSqQSEiOadUSd4E=";
      };
      cargoDeps = rustPlatform.fetchCargoVendor {
        inherit (finalAttrs) src;
        hash = "sha256-FrHkBeTO1RL/hRT0H6okuGdbGiGNljwUOepBsQvrEug=";
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
    patches = (old.patches or [ ]) ++ [ ./portal/remotes.patch ];
    postPatch = (old.postPatch or "") + ''
      cp ${./portal/registry.rs} src/rutabaga_gfx/src/cross_domain/portal_registry.rs
      cp ${../../lib/transport/unix/stream.rs} src/rutabaga_gfx/src/cross_domain/sys/unix_stream.rs
    '';
  })
