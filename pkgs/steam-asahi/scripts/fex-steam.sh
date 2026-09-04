#!/usr/bin/env bash
# shellcheck shell=bash
#
# Configures the x86 FEX environment and starts Steam with its original argv.

set -o errexit
set -o nounset
set -o pipefail

: "${COMMON_SCRIPT:=${BASH_SOURCE[0]%/*}/../../scripts/common.sh}"
# shellcheck source=/dev/null
source "${COMMON_SCRIPT}"
readonly COMMON_SCRIPT
require_configuration_variables STEAM_ASAHI_GUEST_UID

main() {
  (( $# > 0 )) || {
    printf '%s\n' 'usage: fex-steam.sh command [arguments...]' >&2
    return 2
  }

  prepend_colon_path PATH "${GUEST_PATH_ENTRIES[@]}"
  export PULSE_SERVER="unix:/run/user/${STEAM_ASAHI_GUEST_UID}/pulse/native"
  export SDL_AUDIODRIVER=pulseaudio
  prepend_colon_path XDG_DATA_DIRS "${GUEST_DATA_DIRECTORIES[@]}"
  export_default_environment COMMON_DRIVER_ENVIRONMENT
  unset -v GIO_EXTRA_MODULES "${HOST_LOCALE_VARIABLES[@]}"
  export LC_ALL="${C_LOCALE}"
  export LANG="${C_LOCALE}"
  export LOCALE_ARCHIVE="${LOCALE_ARCHIVE_PATH}"
  export TZDIR="${TZDATA_DIRECTORY}"

  exec "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  shopt -s array_expand_once
  main "$@"
fi
