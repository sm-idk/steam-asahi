#!/usr/bin/env bash
# shellcheck shell=bash
#
# Configures the ARM64 Steam guest environment and runs the requested command.

set -o errexit
set -o nounset
set -o pipefail

: "${NATIVE_LIBRARY_PATH:?internal configuration was not injected}"
readonly NATIVE_LIBRARY_PATH

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

main() {
  local data_home="${XDG_DATA_HOME:-${HOME}/.local/share}"
  local status
  local steam_native_directory
  local usage

  printf -v usage '%s%s' \
    'usage: steam-asahi-arm64-guest [--steam] command ' \
    '[arguments...]'

  (( $# > 0 )) || die "${usage}"

  export PATH="/usr/local/bin:/usr/bin:/bin${PATH:+:${PATH}}"
  steam_native_directory="${data_home}/Steam/steamrtarm64"

  # Prefer Valve's coherent client runtime over same-SONAME Nix libraries, then
  # fall back to the system Asahi graphics stack and declared native libraries.
  export LD_LIBRARY_PATH="${steam_native_directory}:\
${steam_native_directory}/libs:\
/run/opengl-driver/lib:\
${NATIVE_LIBRARY_PATH}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
  export PULSE_SERVER="unix:/run/user/${EUID}/pulse/native"
  export SDL_AUDIODRIVER=pulseaudio
  export XDG_DATA_DIRS="/run/opengl-driver/share:\
/run/current-system/sw/share:/usr/local/share:/usr/share\
${XDG_DATA_DIRS:+:${XDG_DATA_DIRS}}"
  export LIBGL_DRIVERS_PATH="${LIBGL_DRIVERS_PATH:-/run/opengl-driver/lib/dri}"
  export __EGL_VENDOR_LIBRARY_DIRS="${__EGL_VENDOR_LIBRARY_DIRS:-\
/run/opengl-driver/share/glvnd/egl_vendor.d}"
  export LIBVA_DRIVERS_PATH="${LIBVA_DRIVERS_PATH:-/run/opengl-driver/lib/dri}"
  export VDPAU_DRIVER_PATH="${VDPAU_DRIVER_PATH:-/run/opengl-driver/lib/vdpau}"
  export VK_DRIVER_FILES="${VK_DRIVER_FILES:-\
/run/opengl-driver/share/vulkan/icd.d/asahi_icd.aarch64.json}"
  export MESA_LOADER_DRIVER_OVERRIDE="${MESA_LOADER_DRIVER_OVERRIDE:-asahi}"
  export LC_ALL=C.UTF-8
  export LANG=C.UTF-8
  export LOCALE_ARCHIVE=/run/current-system/sw/lib/locale/locale-archive
  export TZDIR=/usr/share/zoneinfo
  unset GIO_EXTRA_MODULES

  if [[ "${1}" == '--steam' ]]; then
    shift
    (( $# > 0 )) || die 'the --steam option requires a command'

    while true; do
      if "$@"; then
        status=0
      else
        status=$?
      fi

      if (( status != 42 )); then
        return "${status}"
      fi

      printf '%s%s\n' \
        'Steam requested a client restart; relaunching inside the existing ' \
        'microVM...'
      sleep 1
    done
  fi

  exec "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
