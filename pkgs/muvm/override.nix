{
  lib,
  upstream,
  fetchFromGitHub,
  rustPlatform,
  nix-update-script,
}:

let
  muvmOverrideVersion = "0.7.0";
  isCurrent = lib.versionAtLeast upstream.version muvmOverrideVersion;
  overridden = upstream.overrideAttrs (
    finalAttrs: old: {
      version = muvmOverrideVersion;
      src = fetchFromGitHub {
        owner = "AsahiLinux";
        repo = "muvm";
        tag = "muvm-${finalAttrs.version}";
        hash = "sha256-I6MtpnVA1+BvDXzEjP+bCP5w+t8JgOH5oRHuIGwyOys=";
      };
      cargoHash = null;
      cargoDeps = rustPlatform.fetchCargoVendor {
        inherit (finalAttrs) src;
        hash = "sha256-HDHo/NfQM16JU9DbblFw2jxPEhhgdE/EUgBriKg/6uM=";
      };
      passthru = (old.passthru or { }) // {
        updateScript = nix-update-script {
          attrPath = "muvm";
          extraArgs = [
            "--flake"
            "--system=aarch64-linux"
            "--override-filename=pkgs/muvm/override.nix"
          ];
        };
      };
    }
  );
in
(lib.warnIf isCurrent ''
  muvm >= ${muvmOverrideVersion} is now in nixpkgs; its version pin can be removed while retaining the portal transport patch.
'' (if isCurrent then upstream else overridden)).overrideAttrs
  (old: {
    patches = (old.patches or [ ]) ++ [ ./portal/remotes.patch ];
    postPatch = (old.postPatch or "") + ''
      cp ${./portal/pipewire.rs} crates/muvm/src/guest/bin/muvm-portal-pipewire.rs
      cp ${../../lib/transport/unix/stream.rs} crates/muvm/src/guest/bridge/unix_stream.rs
    '';
  })
