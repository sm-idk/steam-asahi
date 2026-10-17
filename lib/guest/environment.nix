{ lib }:
let
  shell = import ./shell.nix { inherit lib; };
in
{
  common = shell.defaults {
    LIBGL_DRIVERS_PATH = "/run/opengl-driver/lib/dri";
    LIBVA_DRIVERS_PATH = "/run/opengl-driver/lib/dri";
    VDPAU_DRIVER_PATH = "/run/opengl-driver/lib/vdpau";
    __EGL_VENDOR_LIBRARY_DIRS = "/run/opengl-driver/share/glvnd/egl_vendor.d";
  };
  arm64 = shell.defaults {
    MESA_LOADER_DRIVER_OVERRIDE = "asahi";
    VK_DRIVER_FILES = "/run/opengl-driver/share/vulkan/icd.d/asahi_icd.aarch64.json";
  };
}
