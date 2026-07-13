{
  lib,
  stdenv,
  writeShellApplication,
  symlinkJoin,
  makeDesktopItem,
  buildEnv,
  replaceVars,
  runCommand,
  shellcheck,
  steam-arm64-client,
  steam-unwrapped,
  muvm,
  bash,
  coreutils,
  util-linux,
  brotli,
  bzip2,
  pciutils,
  lsof,
  file,
  usbutils,
  which,
  xz,
  yad,
  lsb-release,
  xdg-utils,
  xdg-user-dirs,
  glibc,
  libvpx,
  libasyncns,
  libsndfile,
  libssh2,
  libva,
  libvdpau,
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
  gtk3,
  ibus,
  krb5,
  libappindicator-gtk2,
  libcap,
  libGL,
  libdrm,
  libgbm,
  libpulseaudio,
  libpng,
  libsecret,
  libusb1,
  libudev0-shim,
  libxkbcommon,
  libxcrypt,
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
  openssl,
  pango,
  pipewire,
  SDL2,
  speechd-minimal,
  systemd,
  tzdata,
  vulkan-loader,
  zlib,
  zstd,
  memoryMiB ? null,
  vramMiB ? null,
  publishPorts ? [ ],
  extraEnv ? {
    STEAM_RUNTIME = "1";
    PRESSURE_VESSEL_IMPORT_VULKAN_LAYERS = "0";
    GTK_IM_MODULE = "xim";
  },
}:

assert lib.assertMsg (
  memoryMiB == null || (builtins.isInt memoryMiB && memoryMiB > 0)
) "steam-asahi-arm64: memoryMiB must be null or a positive integer";
assert lib.assertMsg (
  vramMiB == null || (builtins.isInt vramMiB && vramMiB > 0)
) "steam-asahi-arm64: vramMiB must be null or a positive integer";
assert lib.assertMsg (
  builtins.isAttrs extraEnv && lib.all builtins.isString (builtins.attrValues extraEnv)
) "steam-asahi-arm64: extraEnv values must be strings";
assert lib.assertMsg (
  builtins.isList publishPorts && lib.all builtins.isString publishPorts
) "steam-asahi-arm64: publishPorts must be a list of muvm port specifications";

let
  # Steam's client runtime is not sufficient on its own: Pressure Vessel also
  # imports host libraries and runs host-side probes. Keep this list explicit,
  # like nixpkgs' Steam runtime, so every guest dependency is visible and
  # independently overridable through callPackage.
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
    gtk3
    ibus
    krb5
    libappindicator-gtk2
    libcap
    libGL
    libdrm
    libgbm
    # CEF probes libpci in addition to invoking the lspci shim.
    pciutils
    libpulseaudio
    libpng
    libsecret
    libusb1
    # SDL3 and CEF still probe the pre-udev-1 compatibility SONAME.
    libudev0-shim
    libvpx
    # Valve's bundled libpulsecommon and libcurl retain these distro-facing
    # dependencies instead of shipping private copies.
    libasyncns
    libsndfile
    libssh2
    openssl
    zstd
    libxkbcommon
    libxcrypt
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
    speechd-minimal
    systemd
    # CEF links these directly even when hardware decoding is unavailable.
    libva
    libvdpau
    vulkan-loader
    zlib
  ];

  nativeRuntime = buildEnv {
    name = "steam-arm64-native-runtime";
    paths = map lib.getLib nativeLibraries;
    pathsToLink = [ "/lib" ];
    # Several packages expose compatibility aliases for the same SONAME. The
    # ordered list above deliberately selects the first provider.
    ignoreCollisions = true;
  };

  renderShell =
    variables: path:
    lib.concatStringsSep "\n" [
      (lib.toShellVars variables)
      (builtins.readFile path)
    ];

  lspciShim = writeShellApplication {
    inheritPath = false;
    name = "steam-asahi-lspci";
    runtimeInputs = [ pciutils ];
    text = builtins.readFile ./scripts/lspci.sh;
  };

  initScript = writeShellApplication {
    inheritPath = false;
    name = "steam-asahi-arm64-init";
    runtimeInputs = [
      coreutils
      util-linux
    ];
    text = renderShell {
      BASH_BIN = lib.getExe bash;
      COREUTILS_BIN = "${lib.getBin coreutils}/bin";
      EXTRA_COMMAND_DIRS = [
        "${lib.getBin file}/bin"
        "${lib.getBin usbutils}/bin"
        "${lib.getBin which}/bin"
        "${lib.getBin xz}/bin"
      ];
      ETC_STUB_DIRS = [
        "ld.so.conf.d"
        "alternatives"
        "xdg"
        "pulse"
      ];
      ETC_STUB_FILES = [
        "ld.so.cache"
        "ld.so.conf"
        "timezone"
      ];
      ETC_SYMLINKS_TO_MATERIALIZE = [
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
      GLIBC_BIN = "${lib.getBin glibc}/bin";
      GLIBC_I18N = "${glibc}/share/i18n";
      LD_LINUX = "${lib.getLib glibc}/lib/ld-linux-aarch64.so.1";
      LDCONFIG = lib.getExe' (lib.getBin glibc) "ldconfig";
      LSB_RELEASE = lib.getExe lsb-release;
      LSOF = lib.getExe lsof;
      LSPCI = lib.getExe lspciShim;
      NATIVE_RUNTIME = "${nativeRuntime}";
      SH_BIN = "${lib.getBin bash}/bin/sh";
      TASKSET = lib.getExe' util-linux "taskset";
      TZDATA_ZONEINFO = "${tzdata}/share/zoneinfo";
      X11_LOCALE = "${libX11}/share/X11/locale";
      XDG_OPEN = lib.getExe' xdg-utils "xdg-open";
      XDG_USER_DIR = lib.getExe' xdg-user-dirs "xdg-user-dir";
      ZENITY = lib.getExe yad;
    } ./scripts/init.sh;
  };

  guestLauncher = writeShellApplication {
    inheritPath = false;
    name = "steam-asahi-arm64-guest";
    runtimeInputs = [ coreutils ];
    runtimeEnv = extraEnv;
    text = renderShell {
      NATIVE_LIBRARY_PATH = lib.makeLibraryPath nativeLibraries;
    } ./scripts/guest.sh;
  };

  armProton = {
    compatibilityToolDirectory = "steam-asahi-proton-11-arm64";
    displayName = "Proton 11.0 (ARM64)";
    protonDirectory = "Proton 11.0 (ARM64)";
    runtimeAppId = "4185400";
    runtimeDirectory = "SteamLinuxRuntime_4-arm64";
    toolName = "proton_11_arm64";
  };

  compatibilityToolVdf = replaceVars ./proton/compatibilitytool.vdf.in {
    inherit (armProton) displayName toolName;
  };

  protonScriptsCheck =
    runCommand "steam-asahi-arm64-proton-scripts-shellcheck"
      {
        nativeBuildInputs = [ shellcheck ];
      }
      ''
        shellcheck --shell=sh \
          ${./proton/run-proton} \
          ${./proton/steam-asahi-proton}
        touch "$out"
      '';

  sourceScriptsCheck =
    runCommand "steam-asahi-arm64-shell-scripts-test"
      {
        nativeBuildInputs = [
          bash
          coreutils
          shellcheck
        ];
      }
      ''
        shellcheck \
          ${./scripts/guest.sh} \
          ${./scripts/init.sh} \
          ${./scripts/launcher.sh} \
          ${./scripts/lspci.sh} \
          ${./tests/scripts.sh}
        bash ${./tests/scripts.sh} ${../..}
        touch "$out"
      '';

  launcher = writeShellApplication {
    inheritPath = false;
    name = "steam-asahi";
    runtimeInputs = [
      coreutils
      yad
    ];
    text = renderShell {
      CLIENT_BOOTSTRAP = "${steam-arm64-client}/share/steam-arm64-client/steamrtarm64";
      CLIENT_UPDATE_CHANNEL = steam-arm64-client.updateChannel;
      COMPATIBILITY_TOOL_DIRECTORY = armProton.compatibilityToolDirectory;
      COMPATIBILITY_TOOL_VDF = "${compatibilityToolVdf}";
      DISPLAY_NAME = armProton.displayName;
      ENV_BIN = lib.getExe' coreutils "env";
      GUEST_LAUNCHER = lib.getExe guestLauncher;
      HOST_LIBRARIES = "${nativeRuntime}/lib";
      INIT_SCRIPT = lib.getExe initScript;
      MEMORY_ARGS = lib.optionals (memoryMiB != null) [ "--mem=${toString memoryMiB}" ];
      MUVM = lib.getExe muvm;
      NETWORK_ARGS = lib.concatMap (specification: [
        "--publish"
        specification
      ]) publishPorts;
      PROTON_DIRECTORY = armProton.protonDirectory;
      PROTON_RUNNER = "${./proton/run-proton}";
      PROTON_WRAPPER = "${./proton/steam-asahi-proton}";
      RUNTIME_APP_ID = armProton.runtimeAppId;
      RUNTIME_DIRECTORY = armProton.runtimeDirectory;
      TOOL_MANIFEST = "${./proton/toolmanifest.vdf}";
      VRAM_ARGS = lib.optionals (vramMiB != null) [ "--vram=${toString vramMiB}" ];
      YAD = lib.getExe yad;
    } ./scripts/launcher.sh;

    meta = {
      description = "Native ARM64 Steam beta launcher for 16K-page Asahi systems via muvm";
      homepage = "https://github.com/sm-idk/steam-asahi";
      # The wrapper source is MIT, but the installable product closes over and
      # launches Valve's unfree redistributable Steam client.
      license = lib.licenses.unfreeRedistributable;
      platforms = [ "aarch64-linux" ];
      mainProgram = "steam-asahi";
    };
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
in
symlinkJoin {
  pname = "steam-asahi-arm64";
  inherit (steam-arm64-client) version;
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
    proton = armProton;
    tests = {
      protonScripts = protonScriptsCheck;
      sourceScripts = sourceScriptsCheck;
    };
  };
}
