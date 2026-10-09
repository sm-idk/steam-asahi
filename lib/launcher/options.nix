{ lib }:

let
  types = {
    cpuList = lib.types.nullOr (
      lib.types.addCheck (lib.types.nonEmptyListOf lib.types.ints.u16) (
        cpus: lib.lists.unique cpus == cpus
      )
    );
    memoryMiB = lib.types.nullOr lib.types.ints.positive;
    vramMiB = lib.types.nullOr lib.types.ints.positive;
    customSteamHomeDir = lib.types.nullOr lib.types.nonEmptyStr;
    extraEnv = lib.types.addCheck (lib.types.attrsOf (lib.types.nullOr lib.types.str)) (
      environment: lib.lists.all lib.strings.isValidPosixName (builtins.attrNames environment)
    );
  };
in
{
  inherit types;

  validate =
    name:
    {
      cpuList,
      memoryMiB,
      vramMiB,
      extraEnv,
      publishPorts,
      customSteamHomeDir ? null,
    }:
    # Container types check their contents during module merging, so package
    # arguments need explicit element checks as well
    assert lib.asserts.assertMsg (
      types.cpuList.check cpuList && (cpuList == null || lib.lists.all lib.types.ints.u16.check cpuList)
    ) "${name}: cpuList must be null or a non-empty list of unique 16-bit CPU IDs";
    assert lib.asserts.assertMsg (types.memoryMiB.check memoryMiB)
      "${name}: memoryMiB must be null or a positive integer";
    assert lib.asserts.assertMsg (types.vramMiB.check vramMiB)
      "${name}: vramMiB must be null or a positive integer";
    assert lib.asserts.assertMsg (
      types.extraEnv.check extraEnv && lib.lists.all builtins.isString (builtins.attrValues extraEnv)
    ) "${name}: extraEnv must contain valid shell variable names and string values";
    assert lib.asserts.assertMsg (
      builtins.isList publishPorts && lib.lists.all builtins.isString publishPorts
    ) "${name}: publishPorts must be a list of muvm port specifications";
    assert lib.asserts.assertMsg (types.customSteamHomeDir.check customSteamHomeDir)
      "${name}: customSteamHomeDir must be null or a non-empty string";
    true;

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
