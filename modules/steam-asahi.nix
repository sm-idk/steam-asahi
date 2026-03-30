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
      default = pkgs.steam-asahi;
      defaultText = lib.literalExpression "pkgs.steam-asahi";
      description = "The steam-asahi package to use.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    hardware.graphics.enable = lib.mkDefault true;
  };
}
