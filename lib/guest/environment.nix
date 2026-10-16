{ lib }:
let
  defaults = lib.concatMapAttrsStringSep "\n" (
    name: value: ''
      if [[ -z "''${${name}-}" ]]; then
        export ${name}=${lib.escapeShellArg value}
      else
        export ${name}
      fi
    ''
  );
in
{
  common = defaults {
    LIBGL_DRIVERS_PATH = "/run/opengl-driver/lib/dri";
    LIBVA_DRIVERS_PATH = "/run/opengl-driver/lib/dri";
    VDPAU_DRIVER_PATH = "/run/opengl-driver/lib/vdpau";
    __EGL_VENDOR_LIBRARY_DIRS = "/run/opengl-driver/share/glvnd/egl_vendor.d";
  };
  arm64 = defaults {
    MESA_LOADER_DRIVER_OVERRIDE = "asahi";
    VK_DRIVER_FILES = "/run/opengl-driver/share/vulkan/icd.d/asahi_icd.aarch64.json";
  };
}
