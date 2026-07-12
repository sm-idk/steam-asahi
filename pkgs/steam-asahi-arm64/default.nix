{
  lib,
  stdenv,
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
  brotli,
  bzip2,
  pciutils,
  yad,
  lsb-release,
  lsof,
  glibc,
  libvpx,
  alsa-lib,
  atk,
  at-spi2-atk,
  cairo,
  cups,
  curl,
  dbus,
  expat,
  fontconfig,
  freetype,
  gdk-pixbuf,
  glib,
  gtk2,
  ibus,
  libGL,
  libdrm,
  libgbm,
  libpulseaudio,
  libpng,
  libusb1,
  libxkbcommon,
  libxcb,
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
  libSM,
  libICE,
  networkmanager,
  nspr,
  nss,
  openal,
  pango,
  pipewire,
  SDL2,
  systemd,
  vulkan-loader,
  zlib,
  memoryMiB ? null,
  extraEnv ? {
    STEAM_RUNTIME = "1";
    PRESSURE_VESSEL_IMPORT_VULKAN_LAYERS = "0";
  },
}:

let
  nativeLibraries = [
    glibc
    stdenv.cc.cc.lib
    brotli
    bzip2
    alsa-lib
    atk
    at-spi2-atk
    cairo
    cups
    curl
    dbus
    expat
    fontconfig
    freetype
    gdk-pixbuf
    glib
    gtk2
    ibus
    libGL
    libdrm
    libgbm
    libpulseaudio
    libpng
    libusb1
    libvpx
    libxkbcommon
    libxcb
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
    libSM
    libICE
    networkmanager
    nspr
    nss
    openal
    pango
    pipewire
    SDL2
    systemd
    vulkan-loader
    zlib
  ];

  nativeLibraryPath = lib.makeLibraryPath nativeLibraries;

  # Keep all native libraries in the launcher's closure. The FHS setup links
  # their contents into conventional ARM64 library directories inside muvm.
  nativeRuntime = buildEnv {
    name = "steam-arm64-native-runtime";
    paths = map lib.getLib nativeLibraries;
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

  lspciShim = writeShellApplication {
    name = "steam-asahi-lspci";
    runtimeInputs = [ pciutils ];
    text = ''
      # Apple Silicon normally has no PCI bus. Steam uses lspci only for
      # diagnostics, so suppress pciutils errors unless a PCI device exists.
      if [[ -d /sys/bus/pci/devices ]]; then
        for device in /sys/bus/pci/devices/*; do
          [[ -e "$device" ]] && exec lspci "$@"
        done
      fi
    '';
  };

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
      mkdir -p /run/fhs/bin /run/fhs/lib/aarch64-linux-gnu /run/fhs/usr
      cp -a /bin/* /run/fhs/bin/ 2>/dev/null || true
      # Pressure Vessel runs basic host-side probes such as `bwrap true`.
      # Steam sanitizes PATH for tool launches, so these commands must also be
      # present at conventional FHS paths rather than only in a Nix PATH.
      for command in ${coreutils}/bin/* ${lib.getBin glibc}/bin/*; do
        ln -sf "$command" "/run/fhs/bin/$(basename "$command")"
      done
      ln -sf ${bash}/bin/bash /run/fhs/bin/bash
      ln -sf ${bash}/bin/sh /run/fhs/bin/sh

      ln -sf ${lib.getExe lspciShim} /run/fhs/bin/lspci
      ln -sf ${lib.getExe lsb-release} /run/fhs/bin/lsb_release
      ln -sf ${lib.getExe yad} /run/fhs/bin/zenity

      cp -a /usr/* /run/fhs/usr/ 2>/dev/null || true
      mkdir -p \
        /run/fhs/usr/bin \
        /run/fhs/usr/lib \
        /run/fhs/usr/lib64 \
        /run/fhs/usr/lib/aarch64-linux-gnu
      for command in ${coreutils}/bin/* ${lib.getBin glibc}/bin/*; do
        ln -sf "$command" "/run/fhs/usr/bin/$(basename "$command")"
      done
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
        ln -sfn "$path" "/run/fhs/lib/aarch64-linux-gnu/$name"
        ln -sfn "$path" "/run/fhs/usr/lib/$name"
        ln -sfn "$path" "/run/fhs/usr/lib64/$name"
        ln -sfn "$path" "/run/fhs/usr/lib/aarch64-linux-gnu/$name"
      done

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
      # HOME alone is insufficient for Steam state isolation: parts of the
      # client consult getpwuid(). Mirror the requested guest HOME in passwd.
      if [[ -n "''${STEAM_ASAHI_GUEST_HOME:-}" && -n "''${STEAM_ASAHI_GUEST_UID:-}" ]]; then
        while IFS=: read -r name password entry_uid gid gecos home shell; do
          if [[ "$entry_uid" == "$STEAM_ASAHI_GUEST_UID" ]]; then
            home="$STEAM_ASAHI_GUEST_HOME"
          fi
          printf '%s:%s:%s:%s:%s:%s:%s\n' \
            "$name" "$password" "$entry_uid" "$gid" "$gecos" "$home" "$shell"
        done < /run/fhs/etc/passwd > /run/fhs/etc/passwd.new
        mv /run/fhs/etc/passwd.new /run/fhs/etc/passwd
      fi

      mkdir -p ${lib.concatMapStringsSep " " (dir: "/run/fhs/etc/${dir}") etcStubDirs}
      touch ${lib.concatMapStringsSep " " (file: "/run/fhs/etc/${file}") etcStubFiles}
      cat > /run/fhs/etc/ld.so.conf <<'EOF'
      /lib
      /lib/aarch64-linux-gnu
      /usr/lib
      /usr/lib64
      /usr/lib/aarch64-linux-gnu
      /run/opengl-driver/lib
      EOF
      mount --bind /run/fhs/etc /etc

      # libcapsule consults Debian's auxiliary cache location while importing
      # host graphics libraries into Pressure Vessel. NixOS has no ld.so cache,
      # so build one from the guest-only FHS tree after its mounts are active.
      mkdir -p \
        /run/fhs/var/cache/ldconfig \
        /run/fhs/var/lib \
        /run/fhs/var/log \
        /run/fhs/var/tmp
      chmod 1777 /run/fhs/var/tmp
      ln -s /run /run/fhs/var/run
      # The unprivileged guest user cannot create a new mountpoint in the
      # inherited /var, but can bind over the existing /var mountpoint.
      mount --bind /run/fhs/var /var
      ${lib.getExe' (lib.getBin glibc) "ldconfig"} \
        -X -f /etc/ld.so.conf -C /var/cache/ldconfig/ld.so.cache
      rm -f /etc/ld.so.cache
      ln -s /var/cache/ldconfig/ld.so.cache /etc/ld.so.cache
    '';
  };

  guestLauncher = writeShellApplication {
    name = "steam-asahi-arm64-guest";
    runtimeInputs = [
      coreutils
      lsof
    ];
    text = ''
      export PATH=/usr/local/bin:/usr/bin:/bin:$PATH
      steam_native_dir="''${XDG_DATA_HOME:-$HOME/.local/share}/Steam/steamrtarm64"
      # Prefer Valve's coherent client runtime over same-SONAME Nix libraries;
      # fall back to the system Asahi graphics stack and declared native libs.
      export LD_LIBRARY_PATH="$steam_native_dir:$steam_native_dir/libs:/run/opengl-driver/lib:${nativeLibraryPath}:''${LD_LIBRARY_PATH:-}"
      uid=$(id -u)
      export PULSE_SERVER="unix:/run/user/$uid/pulse/native"
      export SDL_AUDIODRIVER=pulseaudio
      export VK_DRIVER_FILES=/run/opengl-driver/share/vulkan/icd.d/asahi_icd.aarch64.json
      export MESA_LOADER_DRIVER_OVERRIDE=asahi
      export LC_ALL=C.UTF-8
      export LANG=C.UTF-8
      export LOCALE_ARCHIVE=/run/current-system/sw/lib/locale/locale-archive
      ${extraEnvExports}

      if [[ "''${1:-}" == "--steam" ]]; then
        shift
        while true; do
          if "$@"; then
            status=0
          else
            status=$?
          fi
          if [[ "$status" -ne 42 ]]; then
            exit "$status"
          fi
          echo "Steam requested a client restart; relaunching inside the existing microVM..."
          sleep 1
        done
      fi

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
          -e "STEAM_ASAHI_GUEST_HOME=$HOME" \
          -e "STEAM_ASAHI_GUEST_UID=$(id -u)" \
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

      mkdir -p "$(dirname "$beta_file")" "$HOME/.steam"
      if [[ ! -f "$beta_file" || "$(<"$beta_file")" != "publicbeta" ]]; then
        printf '%s\n' publicbeta > "$beta_file"
      fi
      for link in steam root; do
        if [[ ! -e "$HOME/.steam/$link" && ! -L "$HOME/.steam/$link" ]]; then
          ln -s "$steam_dir" "$HOME/.steam/$link"
        fi
      done
      if [[ ! -e "$HOME/.steam/sdkarm64" && ! -L "$HOME/.steam/sdkarm64" ]]; then
        ln -s "$steam_dir/linuxarm64" "$HOME/.steam/sdkarm64"
      fi
      # Valve currently publishes ARM Proton and its ARM64 runtime as Steam
      # apps but omits both from the compatibility-tool registry delivered to
      # this client. Register a composed local tool once both official payloads
      # are installed. The wrapper recreates the intended Runtime 4 -> Proton
      # layering without modifying Valve's mutable files.
      proton_dir="$steam_dir/steamapps/common/Proton 11.0 (ARM64)"
      runtime_dir="$steam_dir/steamapps/common/SteamLinuxRuntime_4-arm64"
      compat_dir="$steam_dir/compatibilitytools.d/steam-asahi-proton-11-arm64"
      if [[ -x "$proton_dir/proton" && -x "$runtime_dir/_v2-entry-point" ]]; then
        mkdir -p "$compat_dir"
        cat > "$compat_dir/compatibilitytool.vdf.tmp" <<'EOF'
      "compatibilitytools"
      {
        "compat_tools"
        {
          "proton_11_arm64"
          {
            "install_path" "."
            "display_name" "Proton 11.0 (ARM64)"
            "from_oslist" "windows"
            "to_oslist" "linux"
          }
        }
      }
      EOF
        mv "$compat_dir/compatibilitytool.vdf.tmp" "$compat_dir/compatibilitytool.vdf"
        cat > "$compat_dir/toolmanifest.vdf.tmp" <<'EOF'
      "manifest"
      {
        "version" "2"
        "commandline" "/steam-asahi-proton %verb%"
        "compatmanager_layer_name" "proton"
      }
      EOF
        mv "$compat_dir/toolmanifest.vdf.tmp" "$compat_dir/toolmanifest.vdf"
        cat > "$compat_dir/run-proton.tmp" <<'EOF'
      #!/bin/sh
      set -eu
      me="$(readlink -f "$0")"
      here="''${me%/*}"
      export LD_LIBRARY_PATH="$here/host-libs:/usr/lib/pressure-vessel/overrides/lib/aarch64-linux-gnu:/usr/lib/pressure-vessel/overrides/lib:''${LD_LIBRARY_PATH:-}"
      exec python3 "$here/proton/proton" "$@"
      EOF
        mv "$compat_dir/run-proton.tmp" "$compat_dir/run-proton"
        chmod 755 "$compat_dir/run-proton"
        cat > "$compat_dir/steam-asahi-proton.tmp" <<'EOF'
      #!/bin/sh
      set -eu
      me="$(readlink -f "$0")"
      here="''${me%/*}"
      verb="''${1:?missing Steam compatibility verb}"
      shift

      # The ARM beta registers local tools as AppID 0 and can consequently
      # derive compatdata/0. Recover the target game ID from Steam's wrapper.
      app_id=
      for candidate in "''${SteamAppId:-}" "''${SteamGameId:-}" "''${STEAM_COMPAT_APP_ID:-}"; do
        case "$candidate" in
          (""|0|*[!0-9]*) ;;
          (*) app_id="$candidate"; break ;;
        esac
      done
      compat_data="''${STEAM_COMPAT_DATA_PATH:-}"
      if [ -n "$app_id" ]; then
        export STEAM_COMPAT_APP_ID="$app_id"
        if [ "''${compat_data##*/}" = 0 ]; then
          export STEAM_COMPAT_DATA_PATH="''${compat_data%/0}/$app_id"
        fi
      elif [ "''${compat_data##*/}" = 0 ]; then
        # Steam runs tool-level graphics probes without a target game ID.
        export STEAM_COMPAT_DATA_PATH="''${compat_data%/0}/steam-asahi-tool"
      fi
      if [ -n "''${STEAM_COMPAT_DATA_PATH:-}" ]; then
        mkdir -p "$STEAM_COMPAT_DATA_PATH"
      fi

      log="$here/steam-asahi-proton.log"
      {
        printf '\n=== %s verb=%s app=%s compatdata=%s ===\n' \
          "$(date --iso-8601=seconds)" "$verb" "''${app_id:-unknown}" "''${STEAM_COMPAT_DATA_PATH:-unset}"
        printf 'command:'
        printf ' <%s>' "$@"
        printf '\n'
      } >> "$log"

      exec >> "$log" 2>&1
      exec "$here/runtime/_v2-entry-point" --verb="$verb" -- \
        "$here/run-proton" "$verb" "$@"
      EOF
        mv "$compat_dir/steam-asahi-proton.tmp" "$compat_dir/steam-asahi-proton"
        chmod 755 "$compat_dir/steam-asahi-proton"
        ln -sfn "$proton_dir" "$compat_dir/proton"
        ln -sfn "$runtime_dir" "$compat_dir/runtime"
        ln -sfn ${nativeRuntime}/lib "$compat_dir/host-libs"
        rm -f "$steam_dir/compatibilitytools.d/steam-asahi-arm64.vdf"

        if [[ -f "$compat_dir/steam-asahi-proton.log" ]] && \
           [[ $(stat -c %s "$compat_dir/steam-asahi-proton.log") -gt 1048576 ]]; then
          mv -f "$compat_dir/steam-asahi-proton.log" "$compat_dir/steam-asahi-proton.log.old"
        fi
      elif [[ -x "$proton_dir/proton" ]]; then
        echo "ARM Proton is installed, but Steam Linux Runtime 4.0 - Arm64 (AppID 4185400) is missing." >&2
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
      run_guest --steam "$client_dir/steam" -cef-force-occlusion "$@"
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
