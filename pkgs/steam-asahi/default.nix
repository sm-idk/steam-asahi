# Launcher fixes here are informed by ooonea's Codeberg fork:
# https://codeberg.org/ooonea/steam-asahi
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
  yad,
  pulseaudio,
  lsb-release,
  glibc,
  steam-unwrapped,
  memoryMiB ? null,
  extraEnv ? {
    # Conservative baseline only. Per-game performance/compatibility flags
    # (PROTON_USE_WINED3D=1, FEX_X87REDUCEDPRECISION=1) belong in each game's
    # Steam launch options because they can regress other titles.
    FEX_MULTIBLOCK = "0";
    # steam.sh's ldd-based 32-bit glibc probe cannot see FEX's emulated 32-bit
    # support and floods bogus "missing ... libc.so.6" warnings. These skip it.
    STEAMOS = "1";
    STEAM_RUNTIME = "1";
    # Host Vulkan layers live in unusual NixOS/FEX paths and PressureVessel
    # emits internal errors while trying to import them. ICD import still works;
    # layers/overlays can be revisited once there is a cleaner provider model.
    PRESSURE_VESSEL_IMPORT_VULKAN_LAYERS = "0";
  },
}:

let
  extraEnvExports = lib.concatStringsSep " \\\n          " (
    lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v};") extraEnv
  );

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
      cat > /run/fhs/bin/lspci <<'EOF'
      #!/bin/sh
      # Apple Silicon systems normally have no PCI bus. Steam only uses lspci for
      # optional diagnostics, so avoid noisy pciutils errors when there is no PCI.
      if [ -d /sys/bus/pci/devices ]; then
        for dev in /sys/bus/pci/devices/*; do
          [ -e "$dev" ] && exec ${pciutils}/bin/lspci "$@"
        done
      fi
      exit 0
      EOF
      chmod +x /run/fhs/bin/lspci
      ln -sf ${lib.getExe' pulseaudio "pactl"} /run/fhs/bin/pactl
      ln -sf ${lib.getExe lsb-release} /run/fhs/bin/lsb_release
      # Steam sometimes shells out to zenity; yad is already in the closure and
      # is compatible enough for Steam's simple dialogs.
      ln -sf ${lib.getExe yad} /run/fhs/bin/zenity

      # Copy existing /usr contents, then add missing FHS dirs
      cp -a /usr/* /run/fhs/usr/ 2>/dev/null || true
      mkdir -p /run/fhs/usr/bin /run/fhs/usr/lib /run/fhs/usr/lib64
      ln -sf ${coreutils}/bin/env /run/fhs/usr/bin/env
      ln -sf /run/fhs/bin/lspci /run/fhs/usr/bin/lspci
      ln -sf ${lib.getExe' pulseaudio "pactl"} /run/fhs/usr/bin/pactl
      ln -sf ${lib.getExe lsb-release} /run/fhs/usr/bin/lsb_release
      # Steam sometimes shells out to zenity; yad is already in the closure and
      # is compatible enough for Steam's simple dialogs.
      ln -sf ${lib.getExe yad} /run/fhs/usr/bin/zenity

      # PressureVessel can generate missing UTF-8 locales, but it expects the
      # glibc charmaps under /usr/share/i18n. NixOS normally keeps them in /nix.
      mkdir -p /run/fhs/usr/share
      rm -rf /run/fhs/usr/share/i18n
      ln -s ${glibc}/share/i18n /run/fhs/usr/share/i18n

      # Expose host Vulkan metadata at standard FHS paths for GPU discovery and
      # mirror it into PressureVessel's override tree. PressureVessel rejects
      # layers discovered in /usr/share/vulkan unless the matching JSON is also
      # available through /usr/lib/pressure-vessel/overrides/share/vulkan.
      mkdir -p /run/fhs/usr/share/vulkan /run/fhs/usr/lib/pressure-vessel/overrides/share/vulkan
      for subdir in icd.d explicit_layer.d implicit_layer.d; do
        src="/run/opengl-driver/share/vulkan/$subdir"
        [ -e "$src" ] || continue
        rm -rf "/run/fhs/usr/share/vulkan/$subdir"
        ln -s "$src" "/run/fhs/usr/share/vulkan/$subdir"
        mkdir -p "/run/fhs/usr/lib/pressure-vessel/overrides/share/vulkan/$subdir"
        for json in "$src"/*.json; do
          [ -e "$json" ] && ln -sf "$json" "/run/fhs/usr/lib/pressure-vessel/overrides/share/vulkan/$subdir/"
        done
      done

      # Steam creates its overlay/fossilize layer JSONs in the user's XDG dir.
      # Copy any existing ones so PressureVessel accepts them too.
      mkdir -p /run/fhs/usr/lib/pressure-vessel/overrides/share/vulkan/implicit_layer.d
      for layer in /home/*/.local/share/vulkan/implicit_layer.d/steam*.json; do
        [ -f "$layer" ] && cp -f "$layer" /run/fhs/usr/lib/pressure-vessel/overrides/share/vulkan/implicit_layer.d/ 2>/dev/null || true
      done

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

  # Extract Steam bootstrap files at build time from steam-unwrapped source.
  # Raw extraction preserves generic shebangs (no nix patchShebangs), which is
  # required for running under FEX's x86 bash.
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
    startupNotify = true;
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
      # FEX >= 2605 is XDG-aware: ~/.fex-emu is honored only if it already
      # exists (legacy); otherwise the rootfs lives in $XDG_DATA_HOME/fex-emu
      # and Config.json in $XDG_CONFIG_HOME/fex-emu.
      if [[ -d "$HOME/.fex-emu" ]]; then
        fex_data_dir="$HOME/.fex-emu"
        fex_config="$HOME/.fex-emu/Config.json"
      else
        fex_data_dir="''${XDG_DATA_HOME:-$HOME/.local/share}/fex-emu"
        fex_config="''${XDG_CONFIG_HOME:-$HOME/.config}/fex-emu/Config.json"
      fi

      fex_configured=false
      if [[ -d "$fex_data_dir/RootFS" ]]; then
        for f in "$fex_data_dir/RootFS"/*; do
          case "$f" in
            *.ero | *.sqsh | *.img) fex_configured=true; break ;;
          esac
          [[ -d "$f" ]] && { fex_configured=true; break; }
        done
      fi

      if [[ "$fex_configured" = false && -f "$fex_config" ]]; then
        if grep -qE '"RootFS"[[:space:]]*:[[:space:]]*"[^"]+"' "$fex_config" 2>/dev/null; then
          fex_configured=true
        fi
      fi

      if [[ "$fex_configured" = false ]]; then
        echo "FEX rootfs not found. Downloading Fedora 43 rootfs..."
        echo "This is a one-time setup (~1.3GB download)."
        echo
        ${lib.getExe' fex "FEXRootFSFetcher"} --assume-yes --distro-name=Fedora \
            --distro-version=43 --distro-list-first --as-is \
          || die "FEX rootfs download failed. Run 'FEXRootFSFetcher' manually from a terminal, then relaunch steam-asahi."
      fi

      muvm_mem_args=(${lib.optionalString (memoryMiB != null) "--mem=${toString memoryMiB}"})

      # --- Diagnostic mode: run a command through the same microVM + FEX
      # plumbing Steam uses. A bare `muvm -- FEXBash` is not equivalent because
      # the rootfs/FHS setup below is launcher-specific.
      if [[ "''${1:-}" == "--fex" ]]; then
        shift
        [[ $# -gt 0 ]] || die "usage: steam-asahi --fex '<command>'"
        exec ${lib.getExe' coreutils "env"} \
          -u LANGUAGE \
          -u LC_ADDRESS \
          -u LC_COLLATE \
          -u LC_CTYPE \
          -u LC_IDENTIFICATION \
          -u LC_MEASUREMENT \
          -u LC_MESSAGES \
          -u LC_MONETARY \
          -u LC_NAME \
          -u LC_NUMERIC \
          -u LC_PAPER \
          -u LC_TELEPHONE \
          -u LC_TIME \
          LANG=C.UTF-8 \
          LC_ALL=C.UTF-8 \
          ${lib.getExe muvm} \
          --gpu-mode=drm \
          "''${muvm_mem_args[@]}" \
          --execute-pre ${lib.getExe initScript} \
          --interactive \
          -- \
          FEXBash -c "\
            export PATH=/usr/local/bin:/usr/bin:/bin:\$PATH; \
            unset LANGUAGE LC_ADDRESS LC_COLLATE LC_CTYPE LC_IDENTIFICATION LC_MEASUREMENT LC_MESSAGES LC_MONETARY LC_NAME LC_NUMERIC LC_PAPER LC_TELEPHONE LC_TIME; \
            export LC_ALL=C.UTF-8; \
            export LANG=C.UTF-8; \
            $*"
      fi

      # --- Desktop feedback: plain splash until the Steam UI is likely up ---
      if ! [[ -t 0 || -t 1 ]]; then
        splash_marker=$(mktemp)
        ${lib.getExe yad} --no-buttons --center --borders=16 \
          --title="Steam" --window-icon=steam \
          --text="Starting Steam (microVM + FEX)..." &
        splash_pid=$!
        (
          cef_log="$HOME/.local/share/Steam/logs/cef_log.txt"
          ui_started=false
          for _ in $(seq 1 180); do
            kill -0 "$$" 2>/dev/null || break
            if [[ -f "$cef_log" && "$cef_log" -nt "$splash_marker" ]]; then
              ui_started=true
              break
            fi
            sleep 1
          done
          [[ "$ui_started" = true ]] && sleep 10
          kill "$splash_pid" 2>/dev/null || true
          rm -f "$splash_marker"
        ) &
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
      exec ${lib.getExe' coreutils "env"} \
        -u LANGUAGE \
        -u LC_ADDRESS \
        -u LC_COLLATE \
        -u LC_CTYPE \
        -u LC_IDENTIFICATION \
        -u LC_MEASUREMENT \
        -u LC_MESSAGES \
        -u LC_MONETARY \
        -u LC_NAME \
        -u LC_NUMERIC \
        -u LC_PAPER \
        -u LC_TELEPHONE \
        -u LC_TIME \
        LANG=C.UTF-8 \
        LC_ALL=C.UTF-8 \
        ${lib.getExe muvm} \
        --gpu-mode=drm \
        "''${muvm_mem_args[@]}" \
        --execute-pre ${lib.getExe initScript} \
        --interactive \
        -e "PRESSURE_VESSEL_FILESYSTEMS_RO=/nix:/run/opengl-driver" \
        -- \
        FEXBash -c "\
          export PATH=/usr/local/bin:/usr/bin:/bin:\$PATH; \
          export PULSE_SERVER=unix:/run/user/$uid/pulse/native; \
          export SDL_AUDIODRIVER=pulseaudio; \
          unset LANGUAGE LC_ADDRESS LC_COLLATE LC_CTYPE LC_IDENTIFICATION LC_MEASUREMENT LC_MESSAGES LC_MONETARY LC_NAME LC_NUMERIC LC_PAPER LC_TELEPHONE LC_TIME; \
          export LC_ALL=C.UTF-8; \
          export LANG=C.UTF-8; \
          export LOCALE_ARCHIVE=/run/current-system/sw/lib/locale/locale-archive; \
          ${extraEnvExports}
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
