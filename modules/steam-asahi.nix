{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    concatLists
    filterAttrs
    mapAttrs
    mkDefault
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    optional
    optionals
    types
    unique
    ;

  cfg = config.programs.steam-asahi;

  backendPackages = {
    x86-fex = pkgs.steam-asahi;
    arm64 = pkgs.steam-asahi-arm64;
  };

  backendEnvironments = {
    x86-fex = {
      # Conservative x86/FEX baseline. Per-game flags belong in each
      # game's launch options because they can regress other titles.
      FEX_MULTIBLOCK = "0";
      GTK_IM_MODULE = "xim";
      STEAMOS = "1";
      STEAM_RUNTIME = "1";
      PRESSURE_VESSEL_IMPORT_VULKAN_LAYERS = "0";
    };
    arm64 = {
      GTK_IM_MODULE = "xim";
      STEAM_RUNTIME = "1";
      PRESSURE_VESSEL_IMPORT_VULKAN_LAYERS = "0";
    };
  };

  hasPulseAudioServer =
    config.services.pulseaudio.enable
    || (config.services.pipewire.enable && config.services.pipewire.pulse.enable);

  # muvm uses passt for guest networking, so opening the host firewall alone is
  # insufficient. Publish the same ports from the guest to the host whenever a
  # Steam networking feature is enabled.
  publishPorts = unique (concatLists [
    (optionals (cfg.remotePlay.openFirewall || cfg.localNetworkGameTransfers.openFirewall) [
      "27036/udp"
    ])
    (optionals cfg.remotePlay.openFirewall [
      "27036/tcp"
      "27037/tcp"
      "10400/udp"
      "10401/udp"
      "27031-27035/udp"
    ])
    (optionals cfg.dedicatedServer.openFirewall [
      "27015/tcp"
      "27015/udp"
    ])
    (optionals cfg.localNetworkGameTransfers.openFirewall [ "27040/tcp" ])
  ]);

  # muvm marks proxied PipeWire portal clients with a private access property.
  # Its matching WirePlumber policy lives in the source tree but is not
  # installed by nixpkgs' muvm package, so expose that exact-version policy as
  # a normal NixOS WirePlumber config package.
  muvmWirePlumberConfig = pkgs.runCommand "muvm-wireplumber-config-${pkgs.muvm.version}" { } ''
    mkdir -p "$out/share/wireplumber"
    cp -R ${pkgs.muvm.src}/share/wireplumber/. "$out/share/wireplumber/"
  '';
in
{
  # Keep the module self-describing when it is passed around as an evaluated
  # value instead of imported by path.  The class prevents accidental use in
  # another module-system application, while the file/key retain useful
  # diagnostics and path-compatible deduplication semantics.
  _class = "nixos";
  _file = ./steam-asahi.nix;
  key = toString ./steam-asahi.nix;

  options.programs.steam-asahi = {
    enable = mkEnableOption "Steam on Apple Silicon in a 4K-page microVM";

    backend = mkOption {
      type = types.enum [
        "x86-fex"
        "arm64"
      ];
      default = "x86-fex";
      description = ''
        Steam client backend. `x86-fex` runs the established x86 client
        through FEX, while `arm64` runs Valve's experimental native ARM64
        public beta. Both use muvm because Asahi hosts use 16K pages while
        Valve's binaries currently require a conventional 4K-page environment.
      '';
    };

    package = mkOption {
      type = types.package;
      default = backendPackages.${cfg.backend};
      defaultText = lib.literalExpression ''
        if config.programs.steam-asahi.backend == "arm64" then
          pkgs.steam-asahi-arm64
        else
          pkgs.steam-asahi
      '';
      apply =
        package:
        package.override (previous: {
          inherit (cfg) memoryMiB vramMiB;
          # Match nixpkgs' Steam module by preserving customization already
          # applied to the selected package. Module values win per variable,
          # and null continues to mean removal.
          extraEnv = filterAttrs (_: value: value != null) ((previous.extraEnv or { }) // cfg.extraEnv);
          publishPorts = publishPorts;
        });
      description = ''
        The Steam Asahi launcher package to use. The package is overridden with
        {option}`programs.steam-asahi.memoryMiB`,
        {option}`programs.steam-asahi.vramMiB`, and
        {option}`programs.steam-asahi.extraEnv`, plus the guest ports selected
        by the firewall options. Existing `extraEnv` customization on the
        selected package is preserved, while module values take precedence. A
        custom package must accept `memoryMiB`, `vramMiB`, `extraEnv`, and
        `publishPorts` arguments.
      '';
    };

    memoryMiB = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      example = 6144;
      description = ''
        Ceiling for the microVM memory in MiB. When this is `null`, muvm uses
        its default of 80% of total RAM. The ceiling is not reserved up front:
        memory is provided on demand and returned to the host through
        virtio-balloon free-page reporting. On an 8 GiB machine, 6144 MiB
        leaves useful headroom for the host compositor.
      '';
    };

    vramMiB = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      example = 4096;
      description = ''
        Video-memory heap size in MiB reported by the Asahi userspace driver
        inside the microVM. When this is `null`, muvm reports half of total host
        RAM. This controls the driver's `HK_SYSMEM` value; it does not reserve
        that amount of physical memory up front.
      '';
    };

    extraEnv = mkOption {
      type = types.attrsOf (types.nullOr types.str);
      default = { };
      defaultText = lib.literalMD "defaults selected by {option}`programs.steam-asahi.backend`";
      example = {
        MANGOHUD = "1";
        FEX_MULTIBLOCK = null;
      };
      description = ''
        Environment variables exported inside the selected Steam backend.
        Backend defaults are merged per variable, so additional variables do
        not discard them. Set a variable to `null` to remove its backend
        default. Both backends set `GTK_IM_MODULE=xim`, `STEAM_RUNTIME=1`, and
        `PRESSURE_VESSEL_IMPORT_VULKAN_LAYERS=0`. The `x86-fex` backend also
        sets `FEX_MULTIBLOCK=0` and `STEAMOS=1`.
      '';
    };

    remotePlay.openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open the host firewall and publish the microVM ports needed for Steam
        Remote Play.
      '';
    };

    dedicatedServer.openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open the host firewall and publish the microVM ports needed for Source
        Dedicated Server.
      '';
    };

    localNetworkGameTransfers.openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open the host firewall and publish the microVM ports needed for Steam
        Local Network Game Transfers.
      '';
    };

    users = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "alice" ];
      description = ''
        Users to add to the `kvm` group so they can start the rootless muvm
        guest. Membership grants access to hardware virtualization and should
        only be given to trusted users.
      '';
    };
  };

  config = mkMerge [
    {
      # Put defaults in the module configuration rather than the option
      # declaration. Keeping the priority on each value lets users add or
      # override one variable without replacing every backend default.
      programs.steam-asahi.extraEnv = mapAttrs (_: mkDefault) backendEnvironments.${cfg.backend};
    }

    (mkIf cfg.enable {
      assertions = [
        {
          assertion = pkgs.stdenv.hostPlatform.system == "aarch64-linux";
          message = "`programs.steam-asahi` is supported only on aarch64-linux.";
        }
        {
          assertion = !config.programs.steam.enable;
          message = ''
            `programs.steam-asahi` conflicts with `programs.steam`. Disable the
            regular Steam module; Steam Asahi provides its own client and does
            not use host 32-bit graphics.
          '';
        }
        {
          assertion = !config.hardware.graphics.enable32Bit;
          message = ''
            `programs.steam-asahi` conflicts with
            `hardware.graphics.enable32Bit`. Both backends use 64-bit host
            graphics; x86 support is contained inside the guest.
          '';
        }
      ];

      warnings = optional (!hasPulseAudioServer) ''
        `programs.steam-asahi` expects a PulseAudio-compatible socket, but
        neither PipeWire with `services.pipewire.pulse.enable` nor
        `services.pulseaudio.enable` is enabled. Steam may have no audio.
      '';

      environment.systemPackages = [
        cfg.package
        # Useful for direct guest diagnostics documented in the README. The
        # launcher's other dependencies are already referenced by its closure.
        pkgs.muvm
      ];

      # Host Mesa/virglrenderer provides Asahi DRM native-context rendering;
      # steam-hardware supplies the standard controller and input udev rules.
      hardware.graphics.enable = true;
      hardware.steam-hardware.enable = true;

      users.groups.kvm.members = cfg.users;

      services.pipewire.wireplumber.configPackages =
        optionals (config.services.pipewire.wireplumber.enable)
          [ muvmWirePlumberConfig ];

      # Keep these aligned with nixpkgs' regular Steam module. The launcher
      # additionally forwards each enabled port through muvm/passt.
      networking.firewall = mkMerge [
        (mkIf (cfg.remotePlay.openFirewall || cfg.localNetworkGameTransfers.openFirewall) {
          allowedUDPPorts = [ 27036 ]; # Peer discovery
        })

        (mkIf cfg.remotePlay.openFirewall {
          allowedTCPPorts = [
            27036
            27037
          ];
          allowedUDPPorts = [
            10400
            10401
          ];
          allowedUDPPortRanges = [
            {
              from = 27031;
              to = 27035;
            }
          ];
        })

        (mkIf cfg.dedicatedServer.openFirewall {
          allowedTCPPorts = [ 27015 ]; # SRCDS Rcon port
          allowedUDPPorts = [ 27015 ]; # Gameplay traffic
        })

        (mkIf cfg.localNetworkGameTransfers.openFirewall {
          allowedTCPPorts = [ 27040 ]; # Data transfers
        })
      ];
    })
  ];
}
