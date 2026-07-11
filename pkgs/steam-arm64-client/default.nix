{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "steam-arm64-client";
  # Steam's public beta uses a Unix timestamp as its client version.
  version = "1783717985";

  src = fetchurl {
    url = "https://client-update.fastly.steamstatic.com/bins_linuxarm64_linuxarm64.zip.a609bee687aa3f16bb685254768ba4281c3e46e8";
    hash = "sha256-lStXJdoAUQyl+Q776k1It/jzc6mS/HWciLdat0A3SyI=";
  };

  nativeBuildInputs = [ unzip ];
  dontUnpack = true;
  # Preserve Valve's payload byte-for-byte; it is copied to mutable user state
  # before execution and subsequently maintained by Steam's own updater.
  dontPatchELF = true;
  dontPatchShebangs = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/share/steam-arm64-client"
    unzip -q "$src" -d "$out/share/steam-arm64-client"

    # Valve's zip contains three symlink entries whose directory separator is
    # encoded as a literal backslash. Info-ZIP consequently creates separate
    # directories named `steamrtarm64\\libs` and `steamrtarm64\\swiftshader`.
    # Recreate the intended links in the real directory and remove the artifacts.
    root="$out/share/steam-arm64-client"
    rm -f \
      "$root/"'steamrtarm64\libs\libcurl.so' \
      "$root/"'steamrtarm64\libs\libnghttp2.so' \
      "$root/"'steamrtarm64\libs\libnghttp2.so.14'
    rmdir \
      "$root/"'steamrtarm64\libs' \
      "$root/"'steamrtarm64\swiftshader'
    ln -s libcurl.so.4.8.0 \
      "$out/share/steam-arm64-client/steamrtarm64/libs/libcurl.so"
    ln -s libnghttp2.so.14.20.1 \
      "$out/share/steam-arm64-client/steamrtarm64/libs/libnghttp2.so"
    ln -s libnghttp2.so.14.20.1 \
      "$out/share/steam-arm64-client/steamrtarm64/libs/libnghttp2.so.14"

    # The CDN zip is produced with DOS attributes and carries no Unix execute
    # bits. Mark the actual programs/scripts executable while leaving data and
    # shared libraries non-executable.
    client="$out/share/steam-arm64-client/steamrtarm64"
    chmod a+x \
      "$client/fossilize_replay" \
      "$client/gameoverlayui" \
      "$client/gldriverquery" \
      "$client/reaper" \
      "$client/steam" \
      "$client/steam_monitor" \
      "$client/steamerrorreporter" \
      "$client/steamsysinfo" \
      "$client/steamwebhelper" \
      "$client/steamwebhelper.sh" \
      "$client/streaming_client" \
      "$client/vgui_panel_zoo" \
      "$client/vulkandriverquery"

    runHook postInstall
  '';

  passthru = {
    updateChannel = "publicbeta";
    manifestUrl = "https://client-update.fastly.steamstatic.com/steam_client_publicbeta_linuxarm64";
  };

  meta = {
    description = "Bootstrap payload for Valve's public-beta ARM64 Steam client";
    homepage = "https://store.steampowered.com/";
    license = lib.licenses.unfreeRedistributable;
    platforms = [ "aarch64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
