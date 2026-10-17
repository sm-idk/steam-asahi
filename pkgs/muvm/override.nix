{
  upstream,
  fetchFromGitHub,
  rustPlatform,
}:

# Retain the newer upstream accessibility bridge and guest functionality
upstream.overrideAttrs (
  finalAttrs: _old: {
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
  }
)
