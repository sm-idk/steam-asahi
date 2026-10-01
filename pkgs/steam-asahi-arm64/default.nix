{
  lib,
  callPackage,
  stdenv,
  writeShellApplication,
  writeText,
  symlinkJoin,
  makeDesktopItem,
  buildEnv,
  replaceVars,
  runCommand,
  python314,
  steam-arm64-client,
  steam-unwrapped,
  muvm,
  bash,
  coreutils,
  util-linux,
  gawk,
  gnugrep,
  gnused,
  gnutar,
  gzip,
  patchelf,
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
  fribidi,
  gdk-pixbuf,
  glib,
  gtk2,
  gtk3,
  ibus,
  krb5,
  libappindicator,
  libcap,
  libGL,
  libdrm,
  libgbm,
  libpulseaudio,
  libpng,
  libsecret,
  libthai,
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
  wayland,
  zlib,
  zstd,
  cpuList ? null,
  memoryMiB ? null,
  vramMiB ? null,
  publishPorts ? [ ],
  # null uses the default below the caller's original XDG data home
  customSteamHomeDir ? null,
  extraEnv ? (import ../environments.nix).arm64,
}:

assert lib.asserts.assertMsg (
  cpuList == null
  || (
    builtins.isList cpuList
    && cpuList != [ ]
    && lib.lists.all lib.types.ints.u16.check cpuList
    && lib.lists.unique cpuList == cpuList
  )
) "steam-asahi-arm64: cpuList must be null or a non-empty list of unique 16-bit CPU IDs";
assert lib.asserts.assertMsg (
  memoryMiB == null || lib.types.ints.positive.check memoryMiB
) "steam-asahi-arm64: memoryMiB must be null or a positive integer";
assert lib.asserts.assertMsg (
  vramMiB == null || lib.types.ints.positive.check vramMiB
) "steam-asahi-arm64: vramMiB must be null or a positive integer";
assert lib.asserts.assertMsg (
  builtins.isAttrs extraEnv && lib.lists.all builtins.isString (builtins.attrValues extraEnv)
) "steam-asahi-arm64: extraEnv values must be strings";
assert lib.asserts.assertMsg (
  builtins.isList publishPorts && lib.lists.all builtins.isString publishPorts
) "steam-asahi-arm64: publishPorts must be a list of muvm port specifications";
assert lib.asserts.assertMsg (
  customSteamHomeDir == null || (builtins.isString customSteamHomeDir && customSteamHomeDir != "")
) "steam-asahi-arm64: customSteamHomeDir must be null or a non-empty string";

let
  scripts = import ../scripts {
    inherit
      lib
      bash
      writeText
      writeShellApplication
      ;
  };
  muvmArguments = scripts.muvmArguments {
    inherit
      cpuList
      memoryMiB
      vramMiB
      publishPorts
      ;
  };

  gtk2Appindicator = callPackage ./gtk2-appindicator.nix {
    inherit gtk2 libappindicator;
  };

  # Steam's client runtime is not sufficient on its own: Pressure Vessel also
  # imports host libraries and runs host-side probes. Keep this list explicit,
  # like nixpkgs' Steam runtime, so every guest dependency is visible and
  # independently overridable through callPackage
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
    # SDL loads these by SONAME instead of relying on linked dependencies
    fribidi
    libthai
    wayland
    gdk-pixbuf
    glib
    gtk2
    gtk3
    ibus
    krb5
    gtk2Appindicator
    libcap
    libGL
    libdrm
    libgbm
    # CEF probes libpci in addition to invoking the lspci shim
    pciutils
    libpulseaudio
    libpng
    libsecret
    libusb1
    # SDL3 and CEF still probe the pre-udev-1 compatibility SONAME
    libudev0-shim
    libvpx
    # Valve's bundled libpulsecommon and libcurl retain these distro-facing
    # dependencies instead of shipping private copies
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
    # CEF links these directly even when hardware decoding is unavailable
    libva
    libvdpau
    vulkan-loader
    zlib
  ];

  nativeRuntime = buildEnv {
    name = "steam-arm64-native-runtime";
    paths = map lib.attrsets.getLib nativeLibraries;
    pathsToLink = [ "/lib" ];
  };

  lspciShim = scripts.application {
    source = ./scripts/lspci.sh;
    name = "steam-asahi-lspci";
    runtimeInputs = [ pciutils ];
  };

  initScript = scripts.application {
    source = ./scripts/init.sh;
    name = "steam-asahi-arm64-init";
    runtimeInputs = [
      coreutils
      util-linux
    ];
    configuration = {
      BASH_BIN = lib.meta.getExe bash;
      COREUTILS_BIN = "${lib.attrsets.getBin coreutils}/bin";
      EXTRA_COMMAND_DIRS = map (package: "${lib.attrsets.getBin package}/bin") [
        gawk
        gnugrep
        gnused
        gnutar
        gzip
        dbus
        file
        usbutils
        which
        xz
      ];
      GETOPT = lib.meta.getExe' util-linux "getopt";
      GLIBC_BIN = "${lib.attrsets.getBin glibc}/bin";
      GLIBC_I18N = "${glibc}/share/i18n";
      LD_LINUX = "${lib.attrsets.getLib glibc}/lib/ld-linux-aarch64.so.1";
      LDCONFIG = lib.meta.getExe' glibc "ldconfig";
      LSB_RELEASE = lib.meta.getExe lsb-release;
      LSOF = lib.meta.getExe lsof;
      LSPCI = lib.meta.getExe lspciShim;
      NATIVE_RUNTIME = "${nativeRuntime}";
      SH_BIN = "${lib.attrsets.getBin bash}/bin/sh";
      TASKSET = lib.meta.getExe' util-linux "taskset";
      TZDATA_ZONEINFO = "${tzdata}/share/zoneinfo";
      X11_LOCALE = "${libX11}/share/X11/locale";
      XDG_OPEN = lib.meta.getExe' xdg-utils "xdg-open";
      XDG_USER_DIR = lib.meta.getExe' xdg-user-dirs "xdg-user-dir";
      ZENITY = lib.meta.getExe yad;
    };
  };

  guestLauncher = scripts.application {
    source = ./scripts/guest.sh;
    name = "steam-asahi-arm64-guest";
    runtimeInputs = [
      coreutils
      patchelf
    ];
    runtimeEnv = extraEnv;
    configuration = {
      NATIVE_LIBRARY_PATH = "${nativeRuntime}/lib";
    };
  };

  protonConfigurator =
    let
      python = python314.withPackages (packages: [ packages.vdf ]);
    in
    writeShellApplication {
      inheritPath = false;
      name = "steam-asahi-arm64-configure-proton";
      text = ''
        exec ${lib.meta.getExe python} ${./scripts/configure-proton.py} "$@"
      '';
    };

  armProton = {
    compatibilityToolDirectory = "steam-asahi-proton-11-arm64";
    displayName = "Proton 11.0 (ARM64) [Steam Asahi]";
    protonDirectory = "Proton 11.0 (ARM64)";
    runtimeAppId = "4185400";
    runtimeDirectory = "SteamLinuxRuntime_4-arm64";
    toolName = "proton_11_arm64";
  };

  compatibilityToolVdf = replaceVars ./proton/compatibilitytool.vdf.in {
    inherit (armProton) displayName toolName;
  };

  launcher = (callPackage ../scripts/launcher.nix { }) {
    runtimeInputs = [
      coreutils
    ];
    configuration = muvmArguments // {
      BACKEND = "arm64";
      CLIENT_BOOTSTRAP = "${steam-arm64-client}/share/steam-arm64-client/steamrtarm64";
      CLIENT_UPDATE_CHANNEL = steam-arm64-client.updateChannel;
      COMPATIBILITY_TOOL_DIRECTORY = armProton.compatibilityToolDirectory;
      COMPATIBILITY_TOOL_VDF = "${compatibilityToolVdf}";
      CUSTOM_STEAM_HOME_DIR = if customSteamHomeDir == null then "" else customSteamHomeDir;
      DEFAULT_STEAM_HOME_DIR = "steam-asahi-arm64-home";
      DISPLAY_NAME = armProton.displayName;
      GUEST_LAUNCHER = lib.meta.getExe guestLauncher;
      HOST_LIBRARIES = "${nativeRuntime}/lib";
      INIT_SCRIPT = lib.meta.getExe initScript;
      MUVM = lib.meta.getExe muvm;
      PROTON_DIRECTORY = armProton.protonDirectory;
      PROTON_CONFIGURATOR = lib.meta.getExe protonConfigurator;
      PROTON_RUNNER = "${./proton/run-proton}";
      PROTON_TOOL_NAME = armProton.toolName;
      PROTON_WRAPPER = "${./proton/steam-asahi-proton}";
      RUNTIME_APP_ID = armProton.runtimeAppId;
      RUNTIME_DIRECTORY = armProton.runtimeDirectory;
      TOOL_MANIFEST = "${./proton/toolmanifest.vdf}";
      YAD = lib.meta.getExe yad;
    };

    meta = {
      description = "Native ARM64 Steam beta launcher for 16K-page Asahi systems via muvm";
      homepage = "https://github.com/sm-idk/steam-asahi";
      # The wrapper source has no license. The installable product also closes
      # over and launches Valve's unfree redistributable Steam client
      license = lib.licenses.unfree;
      platforms = [ "aarch64-linux" ];
      mainProgram = "steam-asahi";
    };
  };

in
(callPackage ../mk-launcher-package.nix {
  inherit
    makeDesktopItem
    runCommand
    steam-unwrapped
    symlinkJoin
    ;
})
  {
    pname = "steam-asahi-arm64";
    inherit (steam-arm64-client) version;
    inherit launcher;
    desktopName = "Steam (Asahi, ARM64 beta)";
    comment = "Native ARM64 Steam public beta in a 4K-page microVM";
    passthru = {
      inherit
        customSteamHomeDir
        gtk2Appindicator
        nativeRuntime
        steam-arm64-client
        ;
      backend = "arm64";
      proton = armProton;
    };
  }
