{
  pkgs,
  nixpkgs,
  module,
  source,
  formatter,
}:

let
  inherit (pkgs) lib;
  sources = import ./sources.nix { inherit lib; };
  applications =
    lib.mapAttrs' (
      name: value: lib.nameValuePair "fex-${name}" value
    ) pkgs.steam-asahi.shellApplications
    // lib.mapAttrs' (
      name: value: lib.nameValuePair "arm64-${name}" value
    ) pkgs.steam-asahi-arm64.shellApplications
    // {
      renovate = pkgs.callPackage ./renovate.nix { };
      update-arm64-client = pkgs.steam-arm64-client.updateApplication;
      update-x86_64-client = pkgs.steam-x86_64-client.updateApplication;
    };
  # Check the final text without building target-only guest dependencies
  renderedScripts = lib.mapAttrsToList (
    name: application:
    pkgs.writeText "${name}.sh" (builtins.unsafeDiscardStringContext application.text)
  ) applications;
in
(import ../tests {
  inherit pkgs nixpkgs module;
  scriptTestSources = sources.shellTests;
})
// {
  formatting = formatter.check source;
  shellcheck =
    pkgs.runCommand "steam-asahi-shellcheck"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.shellcheck
        ];
      }
      ''
        for script in ${lib.escapeShellArgs renderedScripts}; do
          bash -n "$script"
          shellcheck "$script"
        done
        touch "$out"
      '';
}
