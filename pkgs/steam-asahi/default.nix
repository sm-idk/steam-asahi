{
  lib,
  stdenvNoCC,
  writeShellApplication,
  symlinkJoin,
  makeDesktopItem,
  muvm,
  fex,
  fuse,
  fuse3,
  bash,
  coreutils,
  util-linux,
  gnugrep,
  pciutils,
  squashfuse,
  erofs-utils,
  steam-unwrapped,
}:

let
  # NixOS /etc symlinks that bwrap can't follow — materialize as real files
  etcSymlinksToMaterialize = [
    "host.conf"
    "hosts"
    "localtime"
    "os-release"
    "resolv.conf"
    "nsswitch.conf"
    "group"
    "passwd"
    "machine-id"
  ];

  # Stub dirs/files PressureVessel expects but NixOS doesn't have
  etcStubDirs = [
    "ld.so.conf.d"
    "alternatives"
    "xdg"
    "pulse"
  ];
  etcStubFiles = [
    "ld.so.cache"
    "ld.so.conf"
    "timezone"
  ];

  initScript = writeShellApplication {
    name = "steam-asahi-init";
    runtimeInputs = [
      coreutils
      util-linux
      pciutils
    ];
    text = ''
      # NixOS has no FHS paths — create them on a writable overlay over /usr
      # /bin/bash and /usr/bin/env are needed by scripts
      # /usr/lib and /usr/lib64 are needed by bwrap for PressureVessel/steamwebhelper
      #
      # Strategy: /usr is read-only (host mount), so we create a writable tmpfs
      # overlay with all the FHS paths bwrap/Steam expect, then bind-mount over /usr
      mkdir -p /run/fhs/bin /run/fhs/usr
      cp -a /bin/* /run/fhs/bin/ 2>/dev/null || true
      ln -sf ${bash}/bin/bash /run/fhs/bin/bash
      ln -sf ${bash}/bin/sh /run/fhs/bin/sh

      # Copy existing /usr contents, then add missing FHS dirs
      cp -a /usr/* /run/fhs/usr/ 2>/dev/null || true
      mkdir -p /run/fhs/usr/bin /run/fhs/usr/lib /run/fhs/usr/lib64
      ln -sf ${coreutils}/bin/env /run/fhs/usr/bin/env
      ln -sf ${pciutils}/bin/lspci /run/fhs/usr/bin/lspci

      # PressureVessel Vulkan layer overrides dir (suppresses "Internal error" warnings)
      mkdir -p /run/fhs/usr/lib/pressure-vessel/overrides/share/vulkan/implicit_layer.d

      mount --bind /run/fhs/bin /bin
      mount --bind /run/fhs/usr /usr

      # Fix NixOS /etc for PressureVessel/bwrap compatibility
      #
      # /etc is read-only inside muvm (host filesystem). Same bind-mount approach as /usr
      # bwrap fails on NixOS symlinks (host.conf -> /etc/static/ -> /nix/store/...) when
      # it creates a new mount namespace without FEX's rootfs overlay
      #
      # Fix: copy /etc to writable tmpfs, materialize symlinks, add stubs, bind-mount over
      mkdir -p /run/fhs/etc
      cp -a /etc/. /run/fhs/etc/ 2>/dev/null || true

      # Materialize NixOS symlinks as real files
      for f in ${lib.concatStringsSep " " etcSymlinksToMaterialize}; do
        if [ -L "/run/fhs/etc/$f" ]; then
          target=$(readlink -f "/run/fhs/etc/$f" 2>/dev/null) || continue
          rm -f "/run/fhs/etc/$f"
          if [ -f "$target" ]; then
            cp "$target" "/run/fhs/etc/$f"
          elif [ -d "$target" ]; then
            mkdir -p "/run/fhs/etc/$f" && cp -a "$target/." "/run/fhs/etc/$f/"
          fi
        fi
      done

      # Create stub dirs/files PressureVessel expects but NixOS doesn't have
      mkdir -p ${lib.concatMapStringsSep " " (d: "/run/fhs/etc/${d}") etcStubDirs}
      touch ${lib.concatMapStringsSep " " (f: "/run/fhs/etc/${f}") etcStubFiles}

      mount --bind /run/fhs/etc /etc

      # FEX needs suid fusermount for rootfs overlay mounting
      mkdir -p /run/wrappers
      mount -t tmpfs -o exec,suid tmpfs /run/wrappers
      mkdir -p /run/wrappers/bin
      cp ${lib.getExe' fuse "fusermount"} /run/wrappers/bin/fusermount
      cp ${lib.getExe' fuse3 "fusermount3"} /run/wrappers/bin/fusermount3
      chown root:root /run/wrappers/bin/fusermount /run/wrappers/bin/fusermount3
      chmod u=srx,g=x,o=x /run/wrappers/bin/fusermount /run/wrappers/bin/fusermount3
    '';
  };

  # Extract Steam bootstrap files at build time from steam-unwrapped source
  # Tracks nixpkgs steam-unwrapped version automatically
  # Raw extraction preserves generic shebangs (no nix patchShebangs),
  # which is required for running under FEX's x86 bash
  steamBootstrap = stdenvNoCC.mkDerivation {
    name = "steam-bootstrap-${steam-unwrapped.version}";
    inherit (steam-unwrapped) src;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/steam-launcher"
      cp bin_steam.sh bootstraplinux_ubuntu12_32.tar.xz steam_subscriber_agreement.txt \
        "$out/steam-launcher/"
      runHook postInstall
    '';
  };
  desktopItem = makeDesktopItem {
    name = "steam-asahi";
    desktopName = "Steam (Asahi)";
    comment = "Steam on Apple Silicon via muvm + FEX-Emu";
    exec = "steam-asahi %U";
    icon = "steam";
    categories = [
      "Game"
      "Network"
    ];
    mimeTypes = [
      "x-scheme-handler/steam"
      "x-scheme-handler/steamlink"
    ];
  };

  launcher = writeShellApplication {
    name = "steam-asahi";
    runtimeInputs = [
      coreutils
      gnugrep
      squashfuse
      erofs-utils
    ];
    text = ''
      die() { echo "ERROR: $1" >&2; exit 1; }

      [[ "$(id -u)" -ne 0 ]] || die "Do not run steam-asahi as root"

      # --- Ensure FEX rootfs ---
      fex_configured=false
      fex_dir="$HOME/.fex-emu"

      if [[ -d "$fex_dir/RootFS" ]]; then
        for f in "$fex_dir/RootFS"/*; do
          case "$f" in
            *.ero | *.sqsh | *.img) fex_configured=true; break ;;
          esac
          [[ -d "$f" ]] && { fex_configured=true; break; }
        done
      fi

      if [[ "$fex_configured" = false && -f "$fex_dir/Config.json" ]]; then
        if grep -qE '"RootFS"[[:space:]]*:[[:space:]]*"[^"]+"' "$fex_dir/Config.json" 2>/dev/null; then
          fex_configured=true
        fi
      fi

      if [[ "$fex_configured" = false ]]; then
        echo "FEX rootfs not found. Downloading Fedora 43 rootfs..."
        echo "This is a one-time setup (~1.3GB download)."
        echo
        if ! ${lib.getExe' fex "FEXRootFSFetcher"} --assume-yes --distro-name=Fedora \
            --distro-version=43 --distro-list-first --as-is; then
          echo "Automatic download failed. Trying interactive mode..."
          ${lib.getExe' fex "FEXRootFSFetcher"}
        fi
      fi

      data_dir="''${XDG_DATA_HOME:-$HOME/.local/share}/steam-asahi"
      marker="$data_dir/bootstrap-installed"

      if [[ ! -f "$marker" || ! -f "$data_dir/steam-launcher/bin_steam.sh" ]]; then
        echo "Setting up Steam bootstrap..."
        mkdir -p "$data_dir"
        cp -a ${steamBootstrap}/steam-launcher "$data_dir/"
        echo "ok" > "$marker"
        echo "Steam bootstrap ready."
      fi

      # --- Launch Steam via muvm + FEXBash ---
      steam_args="-cef-force-occlusion''${*:+ $*}"
      uid=$(id -u)

      echo "Launching Steam via muvm + FEX..."
      exec ${lib.getExe muvm} \
        --execute-pre ${lib.getExe initScript} \
        --interactive \
        -e "PRESSURE_VESSEL_FILESYSTEMS_RO=/nix:/run/opengl-driver" \
        -- \
        FEXBash -c "\
          export PULSE_SERVER=unix:/run/user/$uid/pulse/native; \
          export SDL_AUDIODRIVER=pulseaudio; \
          export LC_ALL=C.UTF-8; \
          export LANG=C.UTF-8; \
          export LOCALE_ARCHIVE=/run/current-system/sw/lib/locale/locale-archive; \
          $data_dir/steam-launcher/bin_steam.sh $steam_args"
    '';

    meta = {
      description = "Steam launcher for NixOS on Apple Silicon via muvm + FEX-Emu";
      license = lib.licenses.mit;
      platforms = [ "aarch64-linux" ];
    };
  };
in
symlinkJoin {
  name = "steam-asahi";
  paths = [
    launcher
    desktopItem
  ];
  postBuild = ''
    mkdir -p "$out/share"
    ln -s ${steam-unwrapped}/share/icons "$out/share/icons"
  '';
  inherit (launcher) meta;
}
