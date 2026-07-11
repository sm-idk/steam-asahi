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
      enable = lib.mkEnableOption "Steam on Apple Silicon via muvm + FEX-Emu";

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.steam-asahi.override { inherit (cfg) extraEnv memoryMiB; };
        defaultText = lib.literalExpression "pkgs.steam-asahi";
        description = "The steam-asahi launcher package to use.";
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
        default = {
          # Conservative baseline; per-game compatibility/performance flags like
          # PROTON_USE_WINED3D=1 and FEX_X87REDUCEDPRECISION=1 belong in Steam
          # launch options because they can regress other titles.
          FEX_MULTIBLOCK = "0";
          # Skip steam.sh's ldd-based 32-bit glibc probe: it cannot see FEX's
          # emulated 32-bit support and floods bogus "missing ... libc.so.6" logs.
          STEAMOS = "1";
          STEAM_RUNTIME = "1";
          # Avoid PressureVessel internal errors while importing host Vulkan
          # layers from NixOS/FEX paths. Vulkan ICD import still works.
          PRESSURE_VESSEL_IMPORT_VULKAN_LAYERS = "0";
        };
        description = ''
          Extra environment variables exported inside the FEX/Steam environment.
          Overriding REPLACES the whole default set — repeat any default key you
          still want.
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
          lib.warn "steam-asahi: forcing hardware.graphics.enable32Bit = false; 32-bit x86 support comes from the FEX rootfs, not host 32-bit graphics." false
        else
          value;
    };
  };

  config = lib.mkIf cfg.enable {
    # These are already in the launcher's closure; exposing them in the system
    # PATH makes diagnostics and manual FEXRootFSFetcher refreshes work.
    environment.systemPackages = [
      cfg.package
      pkgs.muvm
      pkgs.fex
      pkgs.squashfuse
      pkgs.erofs-utils
    ];

    # Host-side Mesa/virglrenderer for Asahi DRM native-context rendering.
    hardware.graphics.enable = lib.mkDefault true;

    # Deliberately not set here:
    # - users.*.extraGroups = [ "kvm" ]: per-user host policy.
    # - swap/zswap: machine-level memory policy; see README recommendations.
    # The incompatible programs.steam.enable and hardware.graphics.enable32Bit
    # options are force-disabled with warnings in the option declarations above.
  };
}
