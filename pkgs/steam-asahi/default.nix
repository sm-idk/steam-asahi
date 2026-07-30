# Launcher fixes here are informed by ooonea's Codeberg fork:
# https://codeberg.org/ooonea/steam-asahi
{
  lib,
  stdenvNoCC,
  writeShellApplication,
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
  extraEnv ? {
    # Conservative baseline only. Per-game performance/compatibility flags
    # belong in each game's launch options because they can regress others.
    FEX_MULTIBLOCK = "0";
    # steam.sh cannot see FEX's emulated 32-bit glibc and otherwise emits bogus
    # missing-libc warnings. These variables skip that host-side probe.
    STEAMOS = "1";
    STEAM_RUNTIME = "1";
    # Pressure Vessel cannot cleanly import Vulkan layers from NixOS/FEX paths.
    # ICD import remains enabled; layers can be revisited separately.
    PRESSURE_VESSEL_IMPORT_VULKAN_LAYERS = "0";
    # Match nixpkgs' Steam wrapper so GTK input methods also work when the
    # surrounding locale is not CJK-specific.
    GTK_IM_MODULE = "xim";
  },
}:

assert lib.assertMsg (
  memoryMiB == null || (builtins.isInt memoryMiB && memoryMiB > 0)
) "steam-asahi: memoryMiB must be null or a positive integer";
assert lib.assertMsg (
  vramMiB == null || (builtins.isInt vramMiB && vramMiB > 0)
) "steam-asahi: vramMiB must be null or a positive integer";
assert lib.assertMsg (
  builtins.isAttrs extraEnv && lib.all builtins.isString (builtins.attrValues extraEnv)
) "steam-asahi: extraEnv values must be strings";
assert lib.assertMsg (
  builtins.isList publishPorts && lib.all builtins.isString publishPorts
) "steam-asahi: publishPorts must be a list of muvm port specifications";

let
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
    name = "steam-asahi-init";
    runtimeInputs = [
      coreutils
      util-linux
    ];
    text = renderShell {
      BASH_BIN = lib.getExe bash;
      ENV_BIN = lib.getExe' coreutils "env";
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
      FUSERMOUNT = lib.getExe' fuse "fusermount";
      FUSERMOUNT3 = lib.getExe' fuse3 "fusermount3";
      GLIBC_I18N = "${glibc}/share/i18n";
      LSB_RELEASE = lib.getExe lsb-release;
      LSPCI = lib.getExe lspciShim;
      PACTL = lib.getExe' pulseaudio "pactl";
      SH_BIN = "${lib.getBin bash}/bin/sh";
      ZENITY = lib.getExe yad;
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
          ${./scripts/fex-diagnostic.sh} \
          ${./scripts/fex-steam.sh} \
          ${./scripts/init.sh} \
          ${./scripts/launcher.sh} \
          ${./scripts/lspci.sh}

        diagnostic_output=$(bash -c \
          'exec ${lib.getExe bash} "$@"' steam-asahi-fex \
          ${./scripts/fex-diagnostic.sh} 'printf "%s" "hello world"')
        test "$diagnostic_output" = 'hello world'

        steam_output=$(GIO_EXTRA_MODULES=/host/gio XDG_DATA_DIRS=/host/share \
          STEAM_ASAHI_GUEST_UID=1234 \
          bash -c 'exec ${lib.getExe bash} "$@"' steam-asahi-fex \
          ${./scripts/fex-steam.sh} \
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
      ENV_BIN = lib.getExe' coreutils "env";
      EXTRA_ENVIRONMENT_ARGS = lib.concatLists (
        lib.mapAttrsToList (name: value: [
          "-e"
          "${name}=${value}"
        ]) extraEnv
      );
      FEX_BASH = lib.getExe' fex "FEXBash";
      FEX_DIAGNOSTIC_SCRIPT = "${./scripts/fex-diagnostic.sh}";
      FEX_ROOTFS_FETCHER = lib.getExe' fex "FEXRootFSFetcher";
      FEX_STEAM_SCRIPT = "${./scripts/fex-steam.sh}";
      INIT_SCRIPT = lib.getExe initScript;
      MUVM = lib.getExe muvm;
      MUVM_HOST_MOUNT = muvmHostMount;
      MUVM_MEMORY_ARGS = lib.optionals (memoryMiB != null) [ "--mem=${toString memoryMiB}" ];
      MUVM_NETWORK_ARGS = lib.concatMap (specification: [
        "--publish"
        specification
      ]) publishPorts;
      MUVM_VRAM_ARGS = lib.optionals (vramMiB != null) [ "--vram=${toString vramMiB}" ];
      MUVM_PATH = lib.makeBinPath [
        coreutils
        erofs-utils
        fex
        gnugrep
        squashfuse
      ];
      STEAM_BOOTSTRAP = "${steamBootstrap}/steam-launcher";
      YAD = lib.getExe yad;
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
  ];
  postBuild = ''
    mkdir -p "$out/share"
    ln -s ${steam-unwrapped}/share/icons "$out/share/icons"
  '';
  inherit (launcher) meta;
  passthru = {
    backend = "x86-fex";
    tests.sourceScripts = sourceScriptsCheck;
  };
}
