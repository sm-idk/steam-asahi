# Launcher fixes here are informed by ooonea's Codeberg fork:
# https://codeberg.org/ooonea/steam-asahi
{
  lib,
  callPackage,
  launcherOptions,
  launcherEnvironments,
  guestScripts,
  mkHostLauncher,
  mkLauncherPackage,
  muvm,
  fex,
  fuse,
  fuse3,
  bash,
  python315,
  waypipe,
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
  steam-x86_64-client,
  muvmHostMount ? "/run/muvm-host",
  nativeWayland ? true,
  portalResources ? false,
  cpuList ? null,
  memoryMiB ? null,
  vramMiB ? null,
  publishPorts ? [ ],
  extraEnv ? launcherEnvironments.x86-fex,
}:

assert launcherOptions.validate "steam-asahi" {
  inherit
    cpuList
    memoryMiB
    vramMiB
    extraEnv
    publishPorts
    ;
};

let
  desktop = callPackage ../../../lib/guest/desktop.nix {
    inherit
      muvm
      python315
      waypipe
      nativeWayland
      portalResources
      ;
  };
  scripts = guestScripts.override { inherit bash; };
  muvmArguments = launcherOptions.muvmArguments {
    inherit
      cpuList
      memoryMiB
      vramMiB
      publishPorts
      ;
  };

  fexDiagnostic = scripts.sourceApplication "steam-asahi-fex-diagnostic.sh" ./guest/diagnostic.nix;
  fexSteam = scripts.sourceApplication "steam-asahi-fex-steam.sh" ./guest/steam.nix;

  lspciShim = scripts.application {
    source = ../../../lib/guest/lspci.nix;
    name = "steam-asahi-lspci";
    runtimeInputs = [ pciutils ];
  };

  initScript = scripts.application {
    source = ./guest/init.nix;
    name = "steam-asahi-init";
    runtimeInputs = [
      coreutils
      util-linux
    ];
    configuration = {
      BASH_BIN = lib.meta.getExe bash;
      ENV_BIN = lib.meta.getExe' coreutils "env";
      FUSERMOUNT = lib.meta.getExe' fuse "fusermount";
      FUSERMOUNT3 = lib.meta.getExe' fuse3 "fusermount3";
      GLIBC_I18N = "${glibc}/share/i18n";
      LSB_RELEASE = lib.meta.getExe lsb-release;
      LSPCI = lib.meta.getExe lspciShim;
      PACTL = lib.meta.getExe' pulseaudio "pactl";
      SH_BIN = "${lib.attrsets.getBin bash}/bin/sh";
      ZENITY = lib.meta.getExe yad;
      XDG_OPEN = lib.getExe desktop.opener;
      DESKTOP_DIAGNOSTIC = lib.getExe desktop.diagnostic;
      GAME_LAUNCHER = lib.getExe desktop.game;
    };
  };

  launcher = mkHostLauncher {
    inherit desktop nativeWayland portalResources;
    runtimeInputs = [
      coreutils
      squashfuse
      erofs-utils
    ];
    configuration = muvmArguments // {
      BACKEND = "x86-fex";
      EXTRA_ENVIRONMENT = extraEnv;
      FEX_BASH = lib.meta.getExe' fex "FEXBash";
      FEX_DIAGNOSTIC_SCRIPT = lib.getExe fexDiagnostic;
      FEX_ROOTFS_FETCHER = lib.meta.getExe' fex "FEXRootFSFetcher";
      FEX_STEAM_SCRIPT = lib.getExe fexSteam;
      INIT_SCRIPT = lib.meta.getExe initScript;
      MUVM = lib.meta.getExe muvm;
      MUVM_HOST_MOUNT = muvmHostMount;
      MUVM_PATH = lib.strings.makeBinPath [
        coreutils
        erofs-utils
        fex
        gnugrep
        squashfuse
      ];
      CLIENT_BOOTSTRAP = "${steam-x86_64-client}/share/steam-x86_64-client/steamrt64";
      CLIENT_UPDATE_CHANNEL = steam-x86_64-client.updateChannel;
      YAD = lib.meta.getExe yad;
    };

    meta = {
      description = "Steam launcher for NixOS on Apple Silicon via muvm + FEX-Emu";
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
  pname = "steam-asahi";
  inherit (steam-x86_64-client) version;
  inherit launcher;
  desktopName = "Steam (Asahi)";
  comment = "64-bit Steam beta on Apple Silicon via muvm + FEX-Emu";
  passthru = {
    inherit nativeWayland portalResources;
    inherit steam-x86_64-client;
    shellApplications = {
      inherit launcher;
      init = initScript;
      desktopOpener = desktop.opener;
      session = desktop.session;
      desktopDiagnostic = desktop.diagnostic;
      gameLauncher = desktop.game;
      lspci = lspciShim;
      diagnostic = fexDiagnostic;
      steam = fexSteam;
    };
    inherit (steam-x86_64-client) updateScript;
    backend = "x86-fex";
  };
}
