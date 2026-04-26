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
  options.programs.steam-asahi = {
    enable = lib.mkEnableOption "Steam on Apple Silicon via muvm + FEX-Emu";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.steam-asahi.override { inherit (cfg) extraEnv; };
      defaultText = lib.literalExpression "pkgs.steam-asahi";
      description = "The steam-asahi package to use.";
    };

    extraEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        FEX_X87REDUCEDPRECISION = "1";
        FEX_MULTIBLOCK = "0";
        PROTON_USE_WINED3D = "1";
      };
      description = "Extra environment variables passed to games inside the FEX/Steam environment.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    hardware.graphics.enable = lib.mkDefault true;
  };
}
