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
  version = "1794266161";

  src = fetchurl {
    url = "https://client-update.fastly.steamstatic.com/steam_steamrt_steamrt64.zip.3c0f2683838a5456c50c3dd46e9ebc5c834e3cf7";
    hash = "sha256-Zh/M1o+68Xc5WNH/I9wql432NFvsWUj+hfnTnKTRRWY=";
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
        "--system=${stdenvNoCC.hostPlatform.system}"
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
