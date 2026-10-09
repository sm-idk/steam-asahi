{
  lib,
  callPackage,
  launcherOptions,
  launcherEnvironments,
  guestScripts,
  mkHostLauncher,
  mkLauncherPackage,
  writeShellApplication,
  replaceVars,
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
  dbus,
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
  tzdata,
  libX11,
  nativeRuntime ? callPackage ./runtime.nix {
    inherit
      glibc
      dbus
      pciutils
      libX11
      ;
  },
  cpuList ? null,
  memoryMiB ? null,
  vramMiB ? null,
  publishPorts ? [ ],
  # null uses the default below the caller's original XDG data home
  customSteamHomeDir ? null,
  extraEnv ? launcherEnvironments.arm64,
}:

assert launcherOptions.validate "steam-asahi-arm64" {
  inherit
    cpuList
    memoryMiB
    vramMiB
    extraEnv
    publishPorts
    customSteamHomeDir
    ;
};

let
  scripts = guestScripts.override { inherit bash; };
  muvmArguments = launcherOptions.muvmArguments {
    inherit
      cpuList
      memoryMiB
      vramMiB
      publishPorts
      ;
  };

  lspciShim = scripts.application {
    source = ./guest/lspci.sh;
    name = "steam-asahi-lspci";
    runtimeInputs = [ pciutils ];
  };

  initScript = scripts.application {
    source = ./guest/init.sh;
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
    source = ./guest/guest.sh;
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
      python = python314.withPackages (packages: [
        packages.boltons
        packages.vdf
      ]);
    in
    writeShellApplication {
      inheritPath = false;
      name = "steam-asahi-arm64-configure-proton";
      text = ''
        exec ${lib.meta.getExe python} ${./proton/configure.py} "$@"
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

  launcher = (mkHostLauncher.override { inherit python314; }) {
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
      PROTON_RUNNER = "${./proton/run}";
      PROTON_TOOL_NAME = armProton.toolName;
      PROTON_WRAPPER = "${./proton/wrapper}";
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
(mkLauncherPackage.override { inherit steam-unwrapped; }) {
  pname = "steam-asahi-arm64";
  inherit (steam-arm64-client) version;
  inherit launcher;
  desktopName = "Steam (Asahi, ARM64 beta)";
  comment = "Native ARM64 Steam public beta in a 4K-page microVM";
  passthru = {
    inherit
      customSteamHomeDir
      nativeRuntime
      steam-arm64-client
      ;
    backend = "arm64";
    proton = armProton;
  }
  // lib.optionalAttrs (nativeRuntime ? gtk2Appindicator) {
    inherit (nativeRuntime) gtk2Appindicator;
  };
}
