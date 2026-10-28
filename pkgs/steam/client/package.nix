{
  lib,
  stdenvNoCC,
  fetchurl,
  callPackage,
  nix-update-script,
  runCommand,
  unzip,
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
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "steam-arm64-client";
  # Steam's public beta uses a Unix timestamp as its client version.
  version = "1793056502";

  src = fetchurl {
    url = "https://client-update.fastly.steamstatic.com/bins_linuxarm64_linuxarm64.zip.22b4de4fb291bb4a8766cdbc2f6721144bda04cd";
    hash = "sha256-UNMFJS7k55dBznw9XISj6K9zF7ZrQtrvMJWghq4WkCg=";
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
    mkdir -p -- "$root"
    unzip -q "$src" -d "$root"

    # Valve's zip contains three symlink entries whose directory separator is
    # encoded as a literal backslash. Info-ZIP consequently creates separate
    # directories named `steamrtarm64\\libs` and `steamrtarm64\\swiftshader`
    # Recreate the intended links in the real directory and remove the artifacts
    ${lib.concatMapAttrsStringSep "\n" (name: target: ''
      rm -f -- "$root/"'steamrtarm64\libs\'${lib.escapeShellArg name}
      ln --symbolic --no-target-directory -- \
        ${lib.escapeShellArg target} "$client/libs/"${lib.escapeShellArg name}
    '') clientLinks}
    rmdir -- \
      "$root/"'steamrtarm64\libs' \
      "$root/"'steamrtarm64\swiftshader'

    # The CDN zip is produced with DOS attributes and carries no Unix execute
    # bits. Mark the actual programs/scripts executable while leaving data and
    # shared libraries non-executable
    chmod a+x -- ${
      lib.concatMapStringsSep " " (name: ''"$client/"${lib.escapeShellArg name}'') clientExecutables
    }

    runHook postInstall
  '';

  passthru = {
    updateChannel = "publicbeta";
    manifestUrl = "https://client-update.fastly.steamstatic.com/steam_client_publicbeta_linuxarm64";
    updateApplication = callPackage ./update.nix {
      inherit finalAttrs;
      manifestRoot = "linuxarm64";
      archive = "bins_linuxarm64_linuxarm64";
      packageFile = "pkgs/steam/client/package.nix";
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
