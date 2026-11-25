{
  lib,
  fetchpatch,
  upstream,
  nix-update-script,
}:
let
  fexOverrideVersion = "2611.1";
  isCurrent = lib.versionAtLeast upstream.version fexOverrideVersion;
  overridden = upstream.overrideAttrs (old: {
    version = fexOverrideVersion;
    src = old.src.overrideAttrs (_: {
      rev = "refs/tags/FEX-${fexOverrideVersion}";
      hash = "sha256-MDn2qprtUXquEBRgu9+sPyBhAw3ulTlQYeWq0Aa/sLM=";
    });
    # CMake 4.5 rejects DEPENDS in install(CODE)
    patches = (old.patches or [ ]) ++ [
      (fetchpatch {
        url = "https://github.com/FEX-Emu/FEX/commit/e1ae133ddd31959b9050b619714950996f21c4ac.patch";
        hash = "sha256-CCjLsfyTeY9ZnCMnGbdQxY77JXOgXLgEJDizqscANIk=";
      })
    ];
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
