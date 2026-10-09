{
  _class = "nixos";
  imports = [ ./modules/steam.nix ];
  nixpkgs.overlays = [ (import ../pkgs/overlay.nix) ];
}
