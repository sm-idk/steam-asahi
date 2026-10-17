{
  lib,
  upstream,
  nix-update-script,
}:
let
  fexOverrideVersion = "2610";
  isCurrent = lib.versionAtLeast upstream.version fexOverrideVersion;
  overridden = upstream.overrideAttrs (old: {
    version = fexOverrideVersion;
    src = old.src.overrideAttrs (_: {
      rev = "refs/tags/FEX-${fexOverrideVersion}";
      hash = "sha256-woTzApJKXAkdxIRMhxu9UO0eXGMJseMUUnhZ4Vb5zgA=";
    });
    doCheck = false;
    passthru = (old.passthru or { }) // {
      updateScript = nix-update-script {
        attrPath = "fex";
        extraArgs = [
          "--flake"
          "--system=aarch64-linux"
          "--override-filename=pkgs/fex/override.nix"
        ];
      };
    };
  });

in
lib.warnIf isCurrent ''
  FEX >= ${fexOverrideVersion} is now in nixpkgs; remove the fex override.
'' (if isCurrent then upstream else overridden)
