{
  upstream,
  fetchFromGitHub,
  rustPlatform,
}:

# Retain the newer upstream accessibility bridge and guest functionality
upstream.overrideAttrs (
  finalAttrs: _old: {
    version = "0.7.0-unstable-2026-09-25";
    src = fetchFromGitHub {
      owner = "AsahiLinux";
      repo = "muvm";
      rev = "b761e07b84652e7fb00df83315907c1809899080";
      hash = "sha256-I6MtpnVA1+BvDXzEjP+bCP5w+t8JgOH5oRHuIGwyOys=";
    };
    cargoHash = null;
    cargoDeps = rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) src;
      hash = "sha256-HDHo/NfQM16JU9DbblFw2jxPEhhgdE/EUgBriKg/6uM=";
    };
  }
)
