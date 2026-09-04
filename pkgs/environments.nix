{
  x86-fex = {
    # Conservative baseline only. Per-game performance/compatibility flags
    # belong in each game's launch options because they can regress others.
    FEX_MULTIBLOCK = "0";
    # steam.sh cannot see FEX's emulated 32-bit glibc and otherwise emits bogus
    # missing-libc warnings. These variables skip that host-side probe.
    STEAMOS = "1";
    STEAM_RUNTIME = "1";
    # Pressure Vessel cannot cleanly import Vulkan layers from NixOS/FEX paths.
    # ICD import remains enabled; layers can be revisited separately.
    PRESSURE_VESSEL_IMPORT_VULKAN_LAYERS = "0";
    # Match nixpkgs' Steam wrapper so GTK input methods also work when the
    # surrounding locale is not CJK-specific.
    GTK_IM_MODULE = "xim";
  };

  arm64 = {
    GTK_IM_MODULE = "xim";
    STEAM_RUNTIME = "1";
    PRESSURE_VESSEL_IMPORT_VULKAN_LAYERS = "0";
  };
}
