{
  lib,
  stdenvNoCC,
  fetchurl,
  curl,
  gnused,
  nix-update-script,
  python314Packages,
  runCommand,
  unzip,
  writeShellApplication,
}:

let
  python314 = python314Packages.python.withPackages (packages: [
    packages.vdf
  ]);
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
    updateScript = lib.getExe (writeShellApplication {
      name = "update-steam-arm64-client";
      runtimeInputs = [
        curl
        gnused
        python314
      ];
      text = ''
        release=$(curl --fail --silent --show-error ${finalAttrs.passthru.manifestUrl} | python3.14 -c '
        import re
        import sys
        import vdf

        release = vdf.load(sys.stdin)["linuxarm64"]
        version = release["version"]
        filename = release["bins_linuxarm64_linuxarm64"]["file"]
        if not (
            re.fullmatch(r"[0-9]+", version)
            and re.fullmatch(
                r"bins_linuxarm64_linuxarm64\.zip\.[0-9a-f]{40}", filename
            )
        ):
            raise SystemExit("unrecognized ARM64 Steam manifest")
        print(version, filename)
        ')
        read -r version filename <<< "$release"
        if [[ "$version" == "${finalAttrs.version}" && "$filename" == "${builtins.baseNameOf finalAttrs.src.url}" ]]; then
          echo "steam-arm64-client $version is already up to date"
          exit 0
        fi

        package=pkgs/steam/client/package.nix
        backup=$(mktemp)
        cp "$package" "$backup"
        trap 'cp "$backup" "$package"; rm -f "$backup"' EXIT
        sed -i -E \
          's#^([[:blank:]]*url = ")https://client-update\.fastly\.steamstatic\.com/bins_linuxarm64_linuxarm64\.zip\.[0-9a-f]+(";)#\1https://client-update.fastly.steamstatic.com/'"$filename"'\2#' \
          "$package"
        if [[ "$version" == "${finalAttrs.version}" ]]; then
          version=skip
        fi
        ${
          lib.escapeShellArgs (nix-update-script {
            attrPath = "steam-arm64-client";
            extraArgs = [
              "--flake"
              "--system=aarch64-linux"
            ];
          })
        } --version="$version"
        trap - EXIT
        rm -f "$backup"
      '';
    });
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
