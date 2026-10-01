# Launcher fixes here are informed by ooonea's Codeberg fork:
# https://codeberg.org/ooonea/steam-asahi
{
  lib,
  callPackage,
  stdenvNoCC,
  writeShellApplication,
  writeText,
  symlinkJoin,
  makeDesktopItem,
  runCommand,
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
  extraEnv ? (import ../environments.nix).x86-fex,
}:

assert lib.asserts.assertMsg (
  cpuList == null
  || (
    builtins.isList cpuList
    && cpuList != [ ]
    && lib.lists.all lib.types.ints.u16.check cpuList
    && lib.lists.unique cpuList == cpuList
  )
) "steam-asahi: cpuList must be null or a non-empty list of unique 16-bit CPU IDs";
assert lib.asserts.assertMsg (
  memoryMiB == null || lib.types.ints.positive.check memoryMiB
) "steam-asahi: memoryMiB must be null or a positive integer";
assert lib.asserts.assertMsg (
  vramMiB == null || lib.types.ints.positive.check vramMiB
) "steam-asahi: vramMiB must be null or a positive integer";
assert lib.asserts.assertMsg (
  builtins.isAttrs extraEnv && lib.lists.all builtins.isString (builtins.attrValues extraEnv)
) "steam-asahi: extraEnv values must be strings";
assert lib.asserts.assertMsg (
  builtins.isList publishPorts && lib.lists.all builtins.isString publishPorts
) "steam-asahi: publishPorts must be a list of muvm port specifications";

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

  fexDiagnosticScript = scripts.renderSource "steam-asahi-fex-diagnostic.sh" ./scripts/fex-diagnostic.sh;
  fexSteamScript = scripts.renderSource "steam-asahi-fex-steam.sh" ./scripts/fex-steam.sh;

  lspciShim = scripts.application {
    source = ./scripts/lspci.sh;
    name = "steam-asahi-lspci";
    runtimeInputs = [ pciutils ];
  };

  initScript = scripts.application {
    source = ./scripts/init.sh;
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

  # Extract Steam bootstrap files without patching their generic shebangs. The
  # scripts must be interpreted by the x86 Bash running through FEX
  steamBootstrap = stdenvNoCC.mkDerivation {
    pname = "steam-bootstrap";
    inherit (steam-unwrapped) version;
    inherit (steam-unwrapped) src;
    strictDeps = true;
    dontPatchShebangs = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/steam-launcher"
      cp bin_steam.sh bootstraplinux_ubuntu12_32.tar.xz steam_subscriber_agreement.txt \
        "$out/steam-launcher/"
      runHook postInstall
    '';
  };

  launcher = (callPackage ../scripts/launcher.nix { }) {
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
(callPackage ../mk-launcher-package.nix {
  inherit
    makeDesktopItem
    runCommand
    steam-unwrapped
    symlinkJoin
    ;
})
  {
    pname = "steam-asahi";
    inherit (steam-unwrapped) version;
    inherit launcher;
    desktopName = "Steam (Asahi)";
    comment = "Steam on Apple Silicon via muvm + FEX-Emu";
    passthru = {
      backend = "x86-fex";
    };
  }
