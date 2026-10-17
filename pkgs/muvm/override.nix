{
  upstream,
  fetchFromGitHub,
  rustPlatform,
  nix-update-script,
}:

# Retain the newer upstream accessibility bridge and guest functionality
upstream.overrideAttrs (
  finalAttrs: old: {
    version = "0.7.0";
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
)
