{
  lib,
  bash,
  writeText,
  writeShellApplication,
}:

assert lib.asserts.assertMsg (lib.versionAtLeast bash.version "5.3")
  "steam-asahi: Bash >= 5.3 is required";

let
  commonScriptSource = ../../src/guest/common.sh;
  commonScript = writeText "steam-asahi-common.sh" (builtins.readFile commonScriptSource);

  # Keep configuration local to the shell, including indexed/associative arrays
  # runtimeEnv exports values and is reserved for the guest's environment
  renderShell =
    variables: path:
    lib.concatStringsSep "\n" [
      (lib.toShellVars ({ COMMON_SCRIPT = commonScript; } // variables))
      (lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile path))
    ];
in
{
  inherit commonScriptSource renderShell;

  # FEX must interpret these sources with its x86 Bash, not a Nix shebang
  renderSource = name: path: writeText name (renderShell { } path);

  application =
    {
      source,
      configuration ? { },
      ...
    }@arguments:
    writeShellApplication (
      removeAttrs arguments [
        "source"
        "configuration"
      ]
      // {
        inheritPath = false;
        text = renderShell configuration source;
      }
    );

}
