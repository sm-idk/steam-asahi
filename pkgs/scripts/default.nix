{
  lib,
  bash,
  writeText,
  writeShellApplication,
}:

assert lib.asserts.assertMsg (lib.versionAtLeast bash.version "5.3")
  "steam-asahi: Bash >= 5.3 is required";

let
  commonScriptSource = ./common.sh;
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

  # Generate argv lists once for both backends, serialized as JSON for Python
  # toShellVars also preserves these lists as arrays for Bash consumers
  muvmArguments =
    {
      cpuList,
      memoryMiB,
      vramMiB,
      publishPorts,
    }:
    {
      CPU_ARGS = lib.optionals (cpuList != null) [
        "--cpu-list=${lib.concatMapStringsSep "," toString cpuList}"
      ];
      MEMORY_ARGS = lib.optionals (memoryMiB != null) [ "--mem=${toString memoryMiB}" ];
      VRAM_ARGS = lib.optionals (vramMiB != null) [ "--vram=${toString vramMiB}" ];
      NETWORK_ARGS = lib.concatMap (specification: [
        "--publish"
        specification
      ]) publishPorts;
    };
}
