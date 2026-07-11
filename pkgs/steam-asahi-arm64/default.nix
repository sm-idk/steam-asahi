{
  lib,
  writeShellApplication,
  symlinkJoin,
  makeDesktopItem,
  buildEnv,
  steam-arm64-client,
  steam-unwrapped,
  muvm,
  bash,
  coreutils,
  util-linux,
  pciutils,
  yad,
  lsb-release,
  glibc,
  libvpx,
  alsa-lib,
  atk,
  at-spi2-atk,
  cairo,
  cups,
  dbus,
  expat,
  fontconfig,
  freetype,
  gdk-pixbuf,
  glib,
  gtk2,
  libGL,
  libdrm,
  libgbm,
  libpulseaudio,
  libxkbcommon,
  libX11,
  libXcomposite,
  libXcursor,
  libXdamage,
  libXext,
  libXfixes,
  libXi,
  libXinerama,
  libXrandr,
  libXrender,
  libXScrnSaver,
  libXtst,
  networkmanager,
  openal,
  pipewire,
  SDL2,
  sdl3,
  systemd,
  vulkan-loader,
  memoryMiB ? null,
  extraEnv ? {
    STEAM_RUNTIME = "1";
    PRESSURE_VESSEL_IMPORT_VULKAN_LAYERS = "0";
  },
}:

let
  nativeLibraries = [
    glibc
    alsa-lib
    atk
    at-spi2-atk
    cairo
    cups
    dbus
    expat
    fontconfig
    freetype
    gdk-pixbuf
    glib
    gtk2
    libGL
    libdrm
    libgbm
    libpulseaudio
    libvpx
    libxkbcommon
    libX11
    libXcomposite
    libXcursor
    libXdamage
    libXext
    libXfixes
    libXi
    libXinerama
    libXrandr
    libXrender
    libXScrnSaver
    libXtst
    networkmanager
    openal
    pipewire
    SDL2
    sdl3
    systemd
    vulkan-loader
  ];

  nativeLibraryPath = lib.makeLibraryPath nativeLibraries;
  libvpxLib = lib.getLib libvpx;

  # Keep all native libraries in the launcher's closure. The FHS setup links
  # their contents into conventional ARM64 library directories inside muvm.
  nativeRuntime = buildEnv {
    name = "steam-arm64-native-runtime";
    paths = nativeLibraries;
    pathsToLink = [ "/lib" ];
    ignoreCollisions = true;
  };

  extraEnvExports = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") extraEnv
  );

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
    name = "steam-asahi-arm64-init";
    runtimeInputs = [
      coreutils
      util-linux
      pciutils
    ];
    text = ''
      # Valve's ARM64 binaries request /lib/ld-linux-aarch64.so.1 and assume a
      # conventional distro filesystem. Construct that filesystem in guest-only
      # tmpfs mounts; no host path is modified by these operations.
      mkdir -p /run/fhs/bin /run/fhs/lib /run/fhs/usr
      cp -a /bin/* /run/fhs/bin/ 2>/dev/null || true
      ln -sf ${bash}/bin/bash /run/fhs/bin/bash
      ln -sf ${bash}/bin/sh /run/fhs/bin/sh

      cat > /run/fhs/bin/lspci <<'EOF'
      #!/bin/sh
      if [ -d /sys/bus/pci/devices ]; then
        for dev in /sys/bus/pci/devices/*; do
          [ -e "$dev" ] && exec ${pciutils}/bin/lspci "$@"
        done
      fi
      exit 0
      EOF
      chmod +x /run/fhs/bin/lspci
      ln -sf ${lib.getExe lsb-release} /run/fhs/bin/lsb_release
      ln -sf ${lib.getExe yad} /run/fhs/bin/zenity

      cp -a /usr/* /run/fhs/usr/ 2>/dev/null || true
      mkdir -p \
        /run/fhs/usr/bin \
        /run/fhs/usr/lib \
        /run/fhs/usr/lib64 \
        /run/fhs/usr/lib/aarch64-linux-gnu
      ln -sf ${coreutils}/bin/env /run/fhs/usr/bin/env
      ln -sf /run/fhs/bin/lspci /run/fhs/usr/bin/lspci
      ln -sf ${lib.getExe lsb-release} /run/fhs/usr/bin/lsb_release
      ln -sf ${lib.getExe yad} /run/fhs/usr/bin/zenity

      # Populate both the dynamic-linker location and Debian/Fedora-style
      # library directories. Steam's own runtime can supersede these later.
      ln -sf ${glibc}/lib/ld-linux-aarch64.so.1 /run/fhs/lib/ld-linux-aarch64.so.1
      for path in ${nativeRuntime}/lib/*; do
        [ -e "$path" ] || continue
        name=$(basename "$path")
        ln -sfn "$path" "/run/fhs/lib/$name"
        ln -sfn "$path" "/run/fhs/usr/lib/$name"
        ln -sfn "$path" "/run/fhs/usr/lib64/$name"
        ln -sfn "$path" "/run/fhs/usr/lib/aarch64-linux-gnu/$name"
      done

      # The beta still requests the older libvpx.so.6 SONAME. The published
      # setup uses a compatibility symlink to the distribution's current
      # libvpx. Keep this experimental workaround confined to the microVM guest.
      if [ -e ${libvpxLib}/lib/libvpx.so ]; then
        ln -sfn ${libvpxLib}/lib/libvpx.so \
          /run/fhs/usr/lib/aarch64-linux-gnu/libvpx.so.6
        ln -sfn ${libvpxLib}/lib/libvpx.so /run/fhs/usr/lib64/libvpx.so.6
        ln -sfn ${libvpxLib}/lib/libvpx.so /run/fhs/usr/lib/libvpx.so.6
      fi

      mkdir -p /run/fhs/usr/share
      rm -rf /run/fhs/usr/share/i18n
      ln -s ${glibc}/share/i18n /run/fhs/usr/share/i18n

      # Expose the system's Asahi Vulkan metadata to the native ARM64 loader and
      # to Pressure Vessel. The JSON files normally reference libraries in the
      # Nix store or /run/opengl-driver, both visible inside muvm.
      mkdir -p \
        /run/fhs/usr/share/vulkan \
        /run/fhs/usr/lib/pressure-vessel/overrides/share/vulkan
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

      mount --bind /run/fhs/bin /bin
      mount --bind /run/fhs/lib /lib
      mount --bind /run/fhs/usr /usr

      mkdir -p /run/fhs/etc
      cp -a /etc/. /run/fhs/etc/ 2>/dev/null || true
      for file in ${lib.concatStringsSep " " etcSymlinksToMaterialize}; do
        if [ -L "/run/fhs/etc/$file" ]; then
          target=$(readlink -f "/run/fhs/etc/$file" 2>/dev/null) || continue
          rm -f "/run/fhs/etc/$file"
          if [ -f "$target" ]; then
            cp "$target" "/run/fhs/etc/$file"
          elif [ -d "$target" ]; then
            mkdir -p "/run/fhs/etc/$file"
            cp -a "$target/." "/run/fhs/etc/$file/"
          fi
        fi
      done
      mkdir -p ${lib.concatMapStringsSep " " (dir: "/run/fhs/etc/${dir}") etcStubDirs}
      touch ${lib.concatMapStringsSep " " (file: "/run/fhs/etc/${file}") etcStubFiles}
      mount --bind /run/fhs/etc /etc
    '';
  };

  guestLauncher = writeShellApplication {
    name = "steam-asahi-arm64-guest";
    runtimeInputs = [ coreutils ];
    text = ''
      export PATH=/usr/local/bin:/usr/bin:/bin:$PATH
      export LD_LIBRARY_PATH=/run/opengl-driver/lib:${nativeLibraryPath}:''${LD_LIBRARY_PATH:-}
      uid=$(id -u)
      export PULSE_SERVER="unix:/run/user/$uid/pulse/native"
      export SDL_AUDIODRIVER=pulseaudio
      export LC_ALL=C.UTF-8
      export LANG=C.UTF-8
      export LOCALE_ARCHIVE=/run/current-system/sw/lib/locale/locale-archive
      ${extraEnvExports}
      exec "$@"
    '';
  };

  desktopItem = makeDesktopItem {
    name = "steam-asahi";
    desktopName = "Steam (Asahi, ARM64 beta)";
    comment = "Native ARM64 Steam public beta in a 4K-page microVM";
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
      yad
    ];
    text = ''
      die() { echo "ERROR: $1" >&2; exit 1; }
      [[ "$(id -u)" -ne 0 ]] || die "Do not run steam-asahi as root"

      muvm_mem_args=(${lib.optionalString (memoryMiB != null) "--mem=${toString memoryMiB}"})

      run_guest() {
        exec ${lib.getExe' coreutils "env"} \
          -u LANGUAGE \
          LANG=C.UTF-8 \
          LC_ALL=C.UTF-8 \
          ${lib.getExe muvm} \
          --gpu-mode=drm \
          "''${muvm_mem_args[@]}" \
          --execute-pre ${lib.getExe initScript} \
          --interactive \
          -e "PRESSURE_VESSEL_FILESYSTEMS_RO=/nix:/run/opengl-driver" \
          -- \
          ${lib.getExe guestLauncher} "$@"
      }

      if [[ "''${1:-}" == "--guest" ]]; then
        shift
        [[ $# -gt 0 ]] || die "usage: steam-asahi --guest command [arguments...]"
        run_guest "$@"
      fi

      steam_dir="''${XDG_DATA_HOME:-$HOME/.local/share}/Steam"
      client_dir="$steam_dir/steamrtarm64"
      beta_file="$steam_dir/package/beta"

      if [[ ! -x "$client_dir/steam" ]]; then
        echo "Installing the pinned ARM64 Steam beta bootstrap..."
        mkdir -p "$steam_dir"
        cp -a ${steam-arm64-client}/share/steam-arm64-client/steamrtarm64 "$steam_dir/"
        chmod -R u+rwX "$client_dir"
      fi

      mkdir -p "$(dirname "$beta_file")"
      if [[ ! -f "$beta_file" || "$(<"$beta_file")" != "publicbeta" ]]; then
        printf '%s\n' publicbeta > "$beta_file"
      fi

      if ! [[ -t 0 || -t 1 ]]; then
        splash_marker=$(mktemp)
        ${lib.getExe yad} --no-buttons --center --borders=16 \
          --title="Steam" --window-icon=steam \
          --text="Starting native ARM64 Steam (4K-page microVM)..." &
        splash_pid=$!
        (
          cef_log="$steam_dir/logs/cef_log.txt"
          for _ in $(seq 1 180); do
            kill -0 "$$" 2>/dev/null || break
            [[ -f "$cef_log" && "$cef_log" -nt "$splash_marker" ]] && break
            sleep 1
          done
          sleep 5
          kill "$splash_pid" 2>/dev/null || true
          rm -f "$splash_marker"
        ) &
      fi

      echo "Launching native ARM64 Steam via muvm..."
      run_guest "$client_dir/steam" -cef-force-occlusion "$@"
    '';

    meta = {
      description = "Native ARM64 Steam beta launcher for 16K-page Asahi systems via muvm";
      license = lib.licenses.mit;
      platforms = [ "aarch64-linux" ];
      mainProgram = "steam-asahi";
    };
  };
in
symlinkJoin {
  name = "steam-asahi-arm64";
  paths = [
    launcher
    desktopItem
  ];
  postBuild = ''
    mkdir -p "$out/share"
    ln -s ${steam-unwrapped}/share/icons "$out/share/icons"
  '';
  inherit (launcher) meta;
  passthru = {
    inherit steam-arm64-client;
    backend = "arm64";
  };
}
