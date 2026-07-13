#!/usr/bin/env bash
# shellcheck shell=bash
#
# Configures the x86 FEX environment and starts Steam with its original argv.

set -o errexit
set -o nounset
set -o pipefail

: "${STEAM_ASAHI_GUEST_UID:?guest UID was not provided}"

main() {
  (( $# > 0 )) || {
    printf '%s\n' 'usage: fex-steam.sh command [arguments...]' >&2
    return 2
  }

  export PATH="/usr/local/bin:/usr/bin:/bin${PATH:+:${PATH}}"
  export PULSE_SERVER="unix:/run/user/${STEAM_ASAHI_GUEST_UID}/pulse/native"
  export SDL_AUDIODRIVER=pulseaudio
  export XDG_DATA_DIRS="/run/opengl-driver/share:\
/run/current-system/sw/share:/usr/local/share:/usr/share\
${XDG_DATA_DIRS:+:${XDG_DATA_DIRS}}"
  export LIBGL_DRIVERS_PATH="${LIBGL_DRIVERS_PATH:-/run/opengl-driver/lib/dri}"
  export __EGL_VENDOR_LIBRARY_DIRS="${__EGL_VENDOR_LIBRARY_DIRS:-\
/run/opengl-driver/share/glvnd/egl_vendor.d}"
  export LIBVA_DRIVERS_PATH="${LIBVA_DRIVERS_PATH:-/run/opengl-driver/lib/dri}"
  export VDPAU_DRIVER_PATH="${VDPAU_DRIVER_PATH:-/run/opengl-driver/lib/vdpau}"
  unset \
    GIO_EXTRA_MODULES \
    LANGUAGE \
    LC_ADDRESS \
    LC_COLLATE \
    LC_CTYPE \
    LC_IDENTIFICATION \
    LC_MEASUREMENT \
    LC_MESSAGES \
    LC_MONETARY \
    LC_NAME \
    LC_NUMERIC \
    LC_PAPER \
    LC_TELEPHONE \
    LC_TIME
  export LC_ALL=C.UTF-8
  export LANG=C.UTF-8
  export LOCALE_ARCHIVE=/run/current-system/sw/lib/locale/locale-archive
  export TZDIR=/usr/share/zoneinfo

  exec "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
