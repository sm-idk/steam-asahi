{
  pkgs,
  nixpkgs,
  module,
  source,
  formatter,
}:

let
  sources = import ./sources.nix { inherit (pkgs) lib; };
in
(import ../tests {
  inherit pkgs nixpkgs module;
  scriptTestSources = sources.shellTests;
})
// {
  formatting = formatter.check source;
  shellcheck = pkgs.testers.shellcheck {
    name = "steam-asahi";
    src = sources.shell;
  };
}
