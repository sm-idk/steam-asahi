{
  lib,
  callPackage,
  nix-update-script,
  stdenvNoCC,
  fetchurl,
  unzip,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "steam-x86_64-client";
  version = "1792110651";

  src = fetchurl {
    url = "https://client-update.fastly.steamstatic.com/steam_steamrt_steamrt64.zip.23be0633bfe7d617b417c3f1691beefb364a49bc";
    hash = "sha256-xGLlUKEmdJpgFSerh1hiuSSZ4WW7mOVFGqbEFcC9gvg=";
  };

  nativeBuildInputs = [ unzip ];
  strictDeps = true;
  dontUnpack = true;
  # Steam copies this bootstrap into mutable state and updates it there
  dontPatchELF = true;
  dontPatchShebangs = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/steam-x86_64-client"
    unzip -q "$src" -d "$out/share/steam-x86_64-client"
    chmod a+x "$out/share/steam-x86_64-client/steamrt64/steam"
    runHook postInstall
  '';

  passthru = {
    updateChannel = "publicbeta";
    manifestUrl = "https://client-update.fastly.steamstatic.com/steam_client_publicbeta_steamrt64";
    updateApplication = callPackage ./update.nix {
      inherit finalAttrs;
      manifestRoot = "steamrt64";
      archive = "steam_steamrt_steamrt64";
      packageFile = "pkgs/steam/client/x86_64.nix";
    };
    updateScript = [
      (lib.getExe finalAttrs.passthru.updateApplication)
    ]
    ++ nix-update-script {
      attrPath = finalAttrs.pname;
      extraArgs = [
        "--flake"
        "--system=aarch64-linux"
      ];
    };
  };

  meta = {
    description = "Bootstrap payload for Valve's public-beta x86_64 Steam client";
    downloadPage = finalAttrs.passthru.manifestUrl;
    homepage = "https://store.steampowered.com/";
    license = lib.licenses.unfreeRedistributable;
    platforms = lib.platforms.linux;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
