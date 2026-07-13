{
  lib,
  stdenvNoCC,
  fetchurl,
  python3,
  runCommand,
  unzip,
  writeText,
}:

let
  updaterFixtureManifest = writeText "steam-arm64-client-updater-manifest" ''
    "linuxarm64"
    {
      "version" "2"
      "bins_linuxarm64_linuxarm64"
      {
        "file" "bins_linuxarm64_linuxarm64.zip.fixture"
        "sha2" "0000000000000000000000000000000000000000000000000000000000000000"
      }
    }
  '';

  updaterFixturePackage = writeText "steam-arm64-client-updater-input.nix" ''
    let
      decoy = {
        version = "fixture";
        src = fetchurl {
          url = "https://example.invalid/fixture.zip";
          hash = "sha256-fixture";
        };
      };
    in
    stdenvNoCC.mkDerivation (finalAttrs: {
      version = "1";
      src = fetchurl {
        url = "https://client-update.fastly.steamstatic.com/old.zip";
        hash = "sha256-old";
      };
    })
  '';

  updaterExpectedPackage = writeText "steam-arm64-client-updater-expected.nix" ''
    let
      decoy = {
        version = "fixture";
        src = fetchurl {
          url = "https://example.invalid/fixture.zip";
          hash = "sha256-fixture";
        };
      };
    in
    stdenvNoCC.mkDerivation (finalAttrs: {
      version = "2";
      src = fetchurl {
        url = "https://client-update.fastly.steamstatic.com/bins_linuxarm64_linuxarm64.zip.fixture";
        hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      };
    })
  '';
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "steam-arm64-client";
  # Steam's public beta uses a Unix timestamp as its client version.
  version = "1783717985";

  src = fetchurl {
    url = "https://client-update.fastly.steamstatic.com/bins_linuxarm64_linuxarm64.zip.a609bee687aa3f16bb685254768ba4281c3e46e8";
    hash = "sha256-lStXJdoAUQyl+Q776k1It/jzc6mS/HWciLdat0A3SyI=";
  };

  nativeBuildInputs = [ unzip ];
  strictDeps = true;
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
    updateScript = ./update.py;
    tests = {
      layout = runCommand "steam-arm64-client-layout-test" { } ''
        share=${finalAttrs.finalPackage}/share/steam-arm64-client
        client="$share/steamrtarm64"

        test -x "$client/steam"
        test -x "$client/steamwebhelper"
        test -x "$client/steamwebhelper.sh"
        test "$(readlink "$client/libs/libcurl.so")" = libcurl.so.4.8.0
        test "$(readlink "$client/libs/libnghttp2.so")" = libnghttp2.so.14.20.1
        test "$(readlink "$client/libs/libnghttp2.so.14")" = libnghttp2.so.14.20.1
        test ! -e "$share/"'steamrtarm64\libs'
        test ! -e "$share/"'steamrtarm64\swiftshader'
        touch "$out"
      '';

      updateScript =
        runCommand "steam-arm64-client-update-script-test"
          {
            nativeBuildInputs = [ python3 ];
          }
          ''
            cp ${updaterFixturePackage} package.nix
            python3 ${./update.py} \
              --manifest-file ${updaterFixtureManifest} \
              package.nix
            diff -u ${updaterExpectedPackage} package.nix
            touch "$out"
          '';
    };
  };

  meta = {
    description = "Bootstrap payload for Valve's public-beta ARM64 Steam client";
    downloadPage = "https://client-update.fastly.steamstatic.com/steam_client_publicbeta_linuxarm64";
    homepage = "https://store.steampowered.com/";
    identifiers.purlParts = {
      type = "generic";
      spec = "valve/${finalAttrs.pname}@${finalAttrs.version}";
    };
    license = lib.licenses.unfreeRedistributable;
    platforms = [ "aarch64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
