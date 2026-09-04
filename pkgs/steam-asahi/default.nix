# Launcher fixes here are informed by ooonea's Codeberg fork:
# https://codeberg.org/ooonea/steam-asahi
{
  lib,
  stdenvNoCC,
  writeShellApplication,
  writeText,
  symlinkJoin,
  makeDesktopItem,
  runCommand,
  shellcheck,
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
  memoryMiB ? null,
  vramMiB ? null,
  publishPorts ? [ ],
  extraEnv ? (import ../environments.nix).x86-fex,
}:

assert lib.asserts.assertMsg (
  memoryMiB == null || (builtins.isInt memoryMiB && memoryMiB > 0)
) "steam-asahi: memoryMiB must be null or a positive integer";
assert lib.asserts.assertMsg (
  vramMiB == null || (builtins.isInt vramMiB && vramMiB > 0)
) "steam-asahi: vramMiB must be null or a positive integer";
assert lib.asserts.assertMsg (
  builtins.isAttrs extraEnv && lib.lists.all builtins.isString (builtins.attrValues extraEnv)
) "steam-asahi: extraEnv values must be strings";
assert lib.asserts.assertMsg (
  builtins.isList publishPorts && lib.lists.all builtins.isString publishPorts
) "steam-asahi: publishPorts must be a list of muvm port specifications";

let
  commonScriptSource = ../scripts/common.sh;
  commonScript = writeText "steam-asahi-common.sh" (builtins.readFile commonScriptSource);

  renderShell =
    variables: path:
    lib.strings.concatStringsSep "\n" [
      (lib.strings.toShellVars variables)
      (builtins.readFile path)
    ];

  renderSource = name: path: writeText name (renderShell { COMMON_SCRIPT = commonScript; } path);

  fexDiagnosticScript = renderSource "steam-asahi-fex-diagnostic.sh" ./scripts/fex-diagnostic.sh;
  fexSteamScript = renderSource "steam-asahi-fex-steam.sh" ./scripts/fex-steam.sh;

  lspciShim = writeShellApplication {
    inheritPath = false;
    name = "steam-asahi-lspci";
    runtimeInputs = [ pciutils ];
    text = renderShell { COMMON_SCRIPT = commonScript; } ./scripts/lspci.sh;
  };

  initScript = writeShellApplication {
    inheritPath = false;
    name = "steam-asahi-init";
    runtimeInputs = [
      coreutils
      util-linux
    ];
    text = renderShell {
      BASH_BIN = lib.meta.getExe bash;
      COMMON_SCRIPT = commonScript;
      ENV_BIN = lib.meta.getExe' coreutils "env";
      FUSERMOUNT = lib.meta.getExe' fuse "fusermount";
      FUSERMOUNT3 = lib.meta.getExe' fuse3 "fusermount3";
      GLIBC_I18N = "${glibc}/share/i18n";
      LSB_RELEASE = lib.meta.getExe lsb-release;
      LSPCI = lib.meta.getExe lspciShim;
      PACTL = lib.meta.getExe' pulseaudio "pactl";
      SH_BIN = "${lib.attrsets.getBin bash}/bin/sh";
      ZENITY = lib.meta.getExe yad;
    } ./scripts/init.sh;
  };

  # Extract Steam bootstrap files without patching their generic shebangs. The
  # scripts must be interpreted by the x86 Bash running through FEX.
  steamBootstrap = stdenvNoCC.mkDerivation {
    pname = "steam-bootstrap";
    inherit (steam-unwrapped) version;
    inherit (steam-unwrapped) src;
    strictDeps = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/steam-launcher"
      cp bin_steam.sh bootstraplinux_ubuntu12_32.tar.xz steam_subscriber_agreement.txt \
        "$out/steam-launcher/"
      runHook postInstall
    '';
  };

  # Keep the desktop icon without retaining the complete Steam client in the
  # launcher's runtime closure. Steam itself is copied from steamBootstrap
  # into mutable user state when the launcher starts.
  steamIcons = runCommand "steam-asahi-icons-${steam-unwrapped.version}" { } ''
    mkdir -p "$out/share"
    cp -R -- ${steam-unwrapped}/share/icons "$out/share/"
  '';

  sourceScriptsCheck =
    runCommand "steam-asahi-source-scripts-shellcheck"
      {
        nativeBuildInputs = [
          bash
          shellcheck
        ];
      }
      ''
        shellcheck \
          ${commonScriptSource} \
          ${./scripts/fex-diagnostic.sh} \
          ${./scripts/fex-steam.sh} \
          ${./scripts/init.sh} \
          ${./scripts/launcher.sh} \
          ${./scripts/lspci.sh}

        diagnostic_output=$(bash -c \
          'exec ${lib.meta.getExe bash} "$@"' steam-asahi-fex \
          ${fexDiagnosticScript} 'printf "%s" "hello world"')
        test "$diagnostic_output" = 'hello world'

        steam_output=$(GIO_EXTRA_MODULES=/host/gio XDG_DATA_DIRS=/host/share \
          STEAM_ASAHI_GUEST_UID=1234 \
          bash -c 'exec ${lib.meta.getExe bash} "$@"' steam-asahi-fex \
          ${fexSteamScript} \
          bash -c 'printf "%s|%s|%s|%s|%s" "$1" "$2" "$PULSE_SERVER" "''${GIO_EXTRA_MODULES-unset}" "$XDG_DATA_DIRS"' \
          steam-asahi 'one two' 'semi;colon')
        test "$steam_output" = \
          'one two|semi;colon|unix:/run/user/1234/pulse/native|unset|/run/opengl-driver/share:/run/current-system/sw/share:/usr/local/share:/usr/share:/host/share'
        touch "$out"
      '';

  launcher = writeShellApplication {
    inheritPath = false;
    name = "steam-asahi";
    runtimeInputs = [
      coreutils
      gnugrep
      squashfuse
      erofs-utils
    ];
    text = renderShell {
      COMMON_SCRIPT = commonScript;
      ENV_BIN = lib.meta.getExe' coreutils "env";
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
      MUVM_MEMORY_ARGS = lib.lists.optionals (memoryMiB != null) [ "--mem=${toString memoryMiB}" ];
      MUVM_NETWORK_ARGS = lib.lists.concatMap (specification: [
        "--publish"
        specification
      ]) publishPorts;
      MUVM_VRAM_ARGS = lib.lists.optionals (vramMiB != null) [ "--vram=${toString vramMiB}" ];
      MUVM_PATH = lib.strings.makeBinPath [
        coreutils
        erofs-utils
        fex
        gnugrep
        squashfuse
      ];
      STEAM_BOOTSTRAP = "${steamBootstrap}/steam-launcher";
      YAD = lib.meta.getExe yad;
    } ./scripts/launcher.sh;

    meta = {
      description = "Steam launcher for NixOS on Apple Silicon via muvm + FEX-Emu";
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
in
symlinkJoin {
  pname = "steam-asahi";
  inherit (steam-unwrapped) version;
  paths = [
    launcher
    desktopItem
    steamIcons
  ];
  inherit (launcher) meta;
  passthru = {
    backend = "x86-fex";
    tests.sourceScripts = sourceScriptsCheck;
  };
}
