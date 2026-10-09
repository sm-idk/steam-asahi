{
  lib,
  pkgs,
  nixpkgs,
  module,
  sourceRoot,
}:
let
  moduleOptions =
    (nixpkgs.lib.nixosSystem {
      modules = [
        module
        { nixpkgs.hostPlatform = "aarch64-linux"; }
      ];
    }).options.programs.steam-asahi;

in
(pkgs.nixosOptionsDoc {
  documentType = "none";
  options.programs.steam-asahi = moduleOptions;
  transformOptions =
    option:
    option
    // {
      declarations = map (
        declaration:
        let
          path = lib.strings.removePrefix "${sourceRoot}/" (toString declaration);
        in
        {
          name = path;
          url = "https://github.com/sm-idk/steam-asahi/blob/main/${path}";
        }
      ) option.declarations;
    };
  warningsAreErrors = true;
}).optionsCommonMark
