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
  muvmHostMount ? "/run/muvm-host",
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
  scripts = guestScripts.override { inherit bash; };
  muvmArguments = launcherOptions.muvmArguments {
    inherit
      cpuList
      memoryMiB
      vramMiB
      publishPorts
      ;
  };

  fexDiagnosticScript = scripts.renderSource "steam-asahi-fex-diagnostic.sh" ./guest/diagnostic.sh;
  fexSteamScript = scripts.renderSource "steam-asahi-fex-steam.sh" ./guest/steam.sh;

  lspciShim = scripts.application {
    source = ./guest/lspci.sh;
    name = "steam-asahi-lspci";
    runtimeInputs = [ pciutils ];
  };

  initScript = scripts.application {
    source = ./guest/init.sh;
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
    };
  };

  steamBootstrap = callPackage ./bootstrap.nix { inherit steam-unwrapped; };

  launcher = mkHostLauncher {
    runtimeInputs = [
      coreutils
      squashfuse
      erofs-utils
    ];
    configuration = muvmArguments // {
      BACKEND = "x86-fex";
      EXTRA_ENVIRONMENT_ARGS = lib.lists.concatLists (
        lib.attrsets.mapAttrsToList (name: value: [
          "-e"
          "${name}=${value}"
        ]) extraEnv
      );
      FEX_BASH = lib.meta.getExe' fex "FEXBash";
      FEX_DIAGNOSTIC_SCRIPT = fexDiagnosticScript;
      FEX_ROOTFS_FETCHER = lib.meta.getExe' fex "FEXRootFSFetcher";
      FEX_STEAM_SCRIPT = fexSteamScript;
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
      STEAM_BOOTSTRAP = "${steamBootstrap}/steam-launcher";
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
  inherit (steam-unwrapped) version;
  inherit launcher;
  desktopName = "Steam (Asahi)";
  comment = "Steam on Apple Silicon via muvm + FEX-Emu";
  passthru = {
    backend = "x86-fex";
  };
}
