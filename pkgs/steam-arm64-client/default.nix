{
  lib,
  stdenvNoCC,
  fetchurl,
  python314,
  runCommand,
  unzip,
  writeText,
}:

let
  # Repair archive paths and permissions from one declarative payload manifest
  clientLinks = {
    "libcurl.so" = "libcurl.so.4.8.0";
    "libnghttp2.so" = "libnghttp2.so.14.20.1";
    "libnghttp2.so.14" = "libnghttp2.so.14.20.1";
  };
  clientExecutables = [
    "fossilize_replay"
    "gameoverlayui"
    "gldriverquery"
    "reaper"
    "steam"
    "steam_monitor"
    "steamerrorreporter"
    "steamsysinfo"
    "steamwebhelper"
    "steamwebhelper.sh"
    "streaming_client"
    "vgui_panel_zoo"
    "vulkandriverquery"
  ];

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
  version = "1791415817";

  src = fetchurl {
    url = "https://client-update.fastly.steamstatic.com/bins_linuxarm64_linuxarm64.zip.c872d902ecd0509ba7c9e49a80aecfd7c462859b";
    hash = "sha256-Z1f+jbMMIKoStIFd+ClX+f20v+WISXpAM2swPxbu/BU=";
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

    root="$out/share/steam-arm64-client"
    client="$root/steamrtarm64"
    ${lib.toShellVars {
      STEAM_CLIENT_LINKS = clientLinks;
      STEAM_CLIENT_EXECUTABLES = clientExecutables;
    }}
    mkdir -p -- "$root"
    unzip -q "$src" -d "$root"

    # Valve's zip contains three symlink entries whose directory separator is
    # encoded as a literal backslash. Info-ZIP consequently creates separate
    # directories named `steamrtarm64\\libs` and `steamrtarm64\\swiftshader`
    # Recreate the intended links in the real directory and remove the artifacts
    for name in "''${!STEAM_CLIENT_LINKS[@]}"; do
      rm -f -- "$root/"'steamrtarm64\libs\'"$name"
      ln --symbolic --no-target-directory -- \
        "''${STEAM_CLIENT_LINKS[$name]}" "$client/libs/$name"
    done
    rmdir -- \
      "$root/"'steamrtarm64\libs' \
      "$root/"'steamrtarm64\swiftshader'

    # The CDN zip is produced with DOS attributes and carries no Unix execute
    # bits. Mark the actual programs/scripts executable while leaving data and
    # shared libraries non-executable
    for name in "''${STEAM_CLIENT_EXECUTABLES[@]}"; do
      chmod a+x -- "$client/$name"
    done

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
            nativeBuildInputs = [ python314 ];
          }
          ''
            cp ${updaterFixturePackage} package.nix
            python3.14 ${./update.py} \
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
