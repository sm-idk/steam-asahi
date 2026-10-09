{ lib, pkgs }:

pkgs.treefmt.withConfig {
  runtimeInputs = builtins.attrValues {
    inherit (pkgs)
      nixf-diagnose
      nixfmt
      ruff
      shfmt
      ;
  };
  settings = {
    on-unmatched = "debug";
    tree-root-file = "flake.nix";
    excludes = [
      ".venv/**"
      ".direnv/**"
      "downloads/**"
    ];
    formatter = {
      nixf-diagnose = {
        command = lib.meta.getExe pkgs.nixf-diagnose;
        includes = [ "*.nix" ];
        options = [
          "--auto-fix"
          "--ignore=sema-unused-def-lambda-noarg-formal"
          "--ignore=sema-unused-def-lambda-witharg-arg"
          "--ignore=sema-unused-def-lambda-witharg-formal"
          "--ignore=sema-unused-def-let"
          "--ignore=sema-primop-removed-prefix"
          "--ignore=sema-primop-overridden"
          "--ignore=sema-constant-overridden"
          "--ignore=sema-primop-unknown"
        ];
        priority = -1;
      };
      python = {
        command = lib.meta.getExe pkgs.ruff;
        includes = [ "*.py" ];
        options = [ "format" ];
      };
      shell = {
        command = lib.meta.getExe pkgs.shfmt;
        includes = [
          ".github/renovate.sh"
          "src/guest/*.sh"
          "pkgs/steam/fex/guest/*.sh"
          "pkgs/steam/arm64/guest/*.sh"
          "pkgs/steam/arm64/proton/run"
          "pkgs/steam/arm64/proton/wrapper"
        ];
        options = [
          "--write"
          "--indent"
          "2"
          "--case-indent"
          "--binary-next-line"
        ];
      };
      nixfmt = {
        command = lib.meta.getExe pkgs.nixfmt;
        includes = [ "*.nix" ];
      };
    };
  };
}
