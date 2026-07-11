{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.steam-asahi;
in
{
  options = {
    programs.steam-asahi = {
      enable = lib.mkEnableOption "Steam on Apple Silicon in a 4K-page microVM";

      backend = lib.mkOption {
        type = lib.types.enum [
          "x86-fex"
          "arm64"
        ];
        default = "x86-fex";
        description = ''
          Steam client backend. `x86-fex` is the established x86 client running
          through FEX; `arm64` is Valve's experimental native ARM64 public beta.
          Both use muvm because Asahi hosts use 16K pages while Valve's binaries
          currently require a conventional 4K-page environment.
        '';
      };

      package = lib.mkOption {
        type = lib.types.package;
        default =
          if cfg.backend == "arm64" then
            pkgs.steam-asahi-arm64.override { inherit (cfg) extraEnv memoryMiB; }
          else
            pkgs.steam-asahi.override { inherit (cfg) extraEnv memoryMiB; };
        defaultText = lib.literalExpression ''
          if config.programs.steam-asahi.backend == "arm64" then
            pkgs.steam-asahi-arm64
          else
            pkgs.steam-asahi
        '';
        description = "Launcher package selected for the configured backend.";
      };

      memoryMiB = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        example = 6144;
        description = ''
          Ceiling for the microVM memory (muvm --mem, MiB). null = muvm default
          (80% of total RAM). The ceiling is not reserved up front: memory is
          provided on demand and returned to the host via virtio-balloon
          free-page reporting. On an 8 GiB machine set 6144 so the host
          compositor keeps headroom; on 16 GiB the default is usually fine.
        '';
      };

      extraEnv = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default =
          if cfg.backend == "arm64" then
            {
              STEAM_RUNTIME = "1";
              PRESSURE_VESSEL_IMPORT_VULKAN_LAYERS = "0";
            }
          else
            {
              # Conservative x86/FEX baseline. Per-game flags belong in each
              # game's Steam launch options because they can regress other titles.
              FEX_MULTIBLOCK = "0";
              STEAMOS = "1";
              STEAM_RUNTIME = "1";
              PRESSURE_VESSEL_IMPORT_VULKAN_LAYERS = "0";
            };
        defaultText = lib.literalExpression "backend-specific defaults";
        description = ''
          Environment variables exported inside the selected Steam backend.
          Overriding replaces the backend's complete default set.
        '';
      };
    };

    programs.steam.enable = lib.mkOption {
      apply =
        value:
        if cfg.enable && value then
          lib.warn "steam-asahi: forcing programs.steam.enable = false; do not enable the regular NixOS Steam module with steam-asahi on aarch64-linux." false
        else
          value;
    };

    hardware.graphics.enable32Bit = lib.mkOption {
      apply =
        value:
        if cfg.enable && value then
          lib.warn "steam-asahi: forcing hardware.graphics.enable32Bit = false; neither backend uses host aarch64 32-bit graphics." false
        else
          value;
    };
  };

  config = lib.mkIf cfg.enable {
    # muvm is useful for diagnostics with either backend. FEX/rootfs utilities
    # are exposed only when the x86 backend is selected.
    environment.systemPackages = [
      cfg.package
      pkgs.muvm
    ]
    ++ lib.optionals (cfg.backend == "x86-fex") [
      pkgs.fex
      pkgs.squashfuse
      pkgs.erofs-utils
    ];

    # Host-side Mesa/virglrenderer for Asahi DRM native-context rendering and
    # standard Steam controller/input udev rules.
    hardware.graphics.enable = lib.mkDefault true;
    hardware.steam-hardware.enable = lib.mkDefault true;

    # Deliberately not set here:
    # - users.*.extraGroups = [ "kvm" ]: per-user host policy.
    # - swap/zswap: machine-level memory policy; see README recommendations.
    # The incompatible programs.steam.enable and hardware.graphics.enable32Bit
    # options are force-disabled with warnings in the option declarations above.
  };
}
