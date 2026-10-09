{ stdenvNoCC, steam-unwrapped }:

# Extract Steam bootstrap files without patching their generic shebangs. The
# scripts must be interpreted by the x86 Bash running through FEX
stdenvNoCC.mkDerivation {
  pname = "steam-bootstrap";
  inherit (steam-unwrapped) version;
  inherit (steam-unwrapped) src;
  strictDeps = true;
  dontPatchShebangs = true;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/steam-launcher"
    cp bin_steam.sh bootstraplinux_ubuntu12_32.tar.xz steam_subscriber_agreement.txt \
      "$out/steam-launcher/"
    runHook postInstall
  '';
}
