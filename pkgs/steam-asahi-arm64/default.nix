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
  writeText,
  python3,
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
  libappindicator,
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
  # null uses the default below the caller's original XDG data home.
  customSteamHomeDir ? null,
  extraEnv ? (import ../environments.nix).arm64,
}:

assert lib.asserts.assertMsg (
  memoryMiB == null || (builtins.isInt memoryMiB && memoryMiB > 0)
) "steam-asahi-arm64: memoryMiB must be null or a positive integer";
assert lib.asserts.assertMsg (
  vramMiB == null || (builtins.isInt vramMiB && vramMiB > 0)
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
  commonScriptSource = ../scripts/common.sh;
  commonScript = writeText "steam-asahi-common.sh" (builtins.readFile commonScriptSource);

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
    libappindicator
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
    paths = map lib.attrsets.getLib nativeLibraries;
    pathsToLink = [ "/lib" ];
    # Several packages expose compatibility aliases for the same SONAME. The
    # ordered list above deliberately selects the first provider.
    ignoreCollisions = true;
  };

  # Copy the desktop icon so the native launcher does not retain the complete
  # x86 Steam client in its runtime closure.
  steamIcons = runCommand "steam-asahi-icons-${steam-unwrapped.version}" { } ''
    mkdir -p "$out/share"
    cp -R -- ${steam-unwrapped}/share/icons "$out/share/"
  '';

  renderShell =
    variables: path:
    lib.strings.concatStringsSep "\n" [
      (lib.strings.toShellVars variables)
      (builtins.readFile path)
    ];

  lspciShim = writeShellApplication {
    inheritPath = false;
    name = "steam-asahi-lspci";
    runtimeInputs = [ pciutils ];
    text = renderShell { COMMON_SCRIPT = commonScript; } ./scripts/lspci.sh;
  };

  initScript = writeShellApplication {
    inheritPath = false;
    name = "steam-asahi-arm64-init";
    runtimeInputs = [
      coreutils
      util-linux
    ];
    text = renderShell {
      BASH_BIN = lib.meta.getExe bash;
      COMMON_SCRIPT = commonScript;
      COREUTILS_BIN = "${lib.attrsets.getBin coreutils}/bin";
      EXTRA_COMMAND_DIRS = [
        "${lib.attrsets.getBin dbus}/bin"
        "${lib.attrsets.getBin file}/bin"
        "${lib.attrsets.getBin usbutils}/bin"
        "${lib.attrsets.getBin which}/bin"
        "${lib.attrsets.getBin xz}/bin"
      ];
      GETOPT = lib.meta.getExe' util-linux "getopt";
      GLIBC_BIN = "${lib.attrsets.getBin glibc}/bin";
      GLIBC_I18N = "${glibc}/share/i18n";
      LD_LINUX = "${lib.attrsets.getLib glibc}/lib/ld-linux-aarch64.so.1";
      LDCONFIG = lib.meta.getExe' (lib.attrsets.getBin glibc) "ldconfig";
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
    } ./scripts/init.sh;
  };

  guestLauncher = writeShellApplication {
    inheritPath = false;
    name = "steam-asahi-arm64-guest";
    runtimeInputs = [ coreutils ];
    runtimeEnv = extraEnv;
    text = renderShell {
      COMMON_SCRIPT = commonScript;
      NATIVE_LIBRARY_PATH = "${nativeRuntime}/lib";
    } ./scripts/guest.sh;
  };

  protonConfigurator = writeShellApplication {
    inheritPath = false;
    name = "steam-asahi-arm64-configure-proton";
    runtimeInputs = [ (python3.withPackages (packages: [ packages.vdf ])) ];
    text = ''
      exec python3 ${./scripts/configure-proton.py} "$@"
    '';
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
          util-linux
        ];
      }
      ''
        shellcheck \
          ${commonScriptSource} \
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
      util-linux
      yad
    ];
    text = renderShell {
      CLIENT_BOOTSTRAP = "${steam-arm64-client}/share/steam-arm64-client/steamrtarm64";
      CLIENT_UPDATE_CHANNEL = steam-arm64-client.updateChannel;
      COMPATIBILITY_TOOL_DIRECTORY = armProton.compatibilityToolDirectory;
      COMPATIBILITY_TOOL_VDF = "${compatibilityToolVdf}";
      COMMON_SCRIPT = commonScript;
      CUSTOM_STEAM_HOME_DIR = if customSteamHomeDir == null then "" else customSteamHomeDir;
      DEFAULT_STEAM_HOME_DIR = "steam-asahi-arm64-home";
      DISPLAY_NAME = armProton.displayName;
      ENV_BIN = lib.meta.getExe' coreutils "env";
      FLOCK = lib.meta.getExe' util-linux "flock";
      GUEST_LAUNCHER = lib.meta.getExe guestLauncher;
      HOST_LIBRARIES = "${nativeRuntime}/lib";
      INIT_SCRIPT = lib.meta.getExe initScript;
      MEMORY_ARGS = lib.lists.optionals (memoryMiB != null) [ "--mem=${toString memoryMiB}" ];
      MUVM = lib.meta.getExe muvm;
      NETWORK_ARGS = lib.lists.concatMap (specification: [
        "--publish"
        specification
      ]) publishPorts;
      PROTON_DIRECTORY = armProton.protonDirectory;
      PROTON_CONFIGURATOR = lib.meta.getExe protonConfigurator;
      PROTON_RUNNER = "${./proton/run-proton}";
      PROTON_TOOL_NAME = armProton.toolName;
      PROTON_WRAPPER = "${./proton/steam-asahi-proton}";
      RUNTIME_APP_ID = armProton.runtimeAppId;
      RUNTIME_DIRECTORY = armProton.runtimeDirectory;
      TOOL_MANIFEST = "${./proton/toolmanifest.vdf}";
      VRAM_ARGS = lib.lists.optionals (vramMiB != null) [ "--vram=${toString vramMiB}" ];
      YAD = lib.meta.getExe yad;
    } ./scripts/launcher.sh;

    meta = {
      description = "Native ARM64 Steam beta launcher for 16K-page Asahi systems via muvm";
      homepage = "https://github.com/sm-idk/steam-asahi";
      # The wrapper source has no license. The installable product also closes
      # over and launches Valve's unfree redistributable Steam client.
      license = lib.licenses.unfree;
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
    steamIcons
  ];
  inherit (launcher) meta;
  passthru = {
    inherit customSteamHomeDir steam-arm64-client;
    backend = "arm64";
    proton = armProton;
    tests = {
      protonScripts = protonScriptsCheck;
      sourceScripts = sourceScriptsCheck;
    };
  };
}
