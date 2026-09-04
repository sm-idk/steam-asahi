#!/usr/bin/env bash
# shellcheck shell=bash
#
# Configures the ARM64 Steam guest environment and runs the requested command.

set -o errexit
set -o nounset
set -o pipefail

: "${COMMON_SCRIPT:=${BASH_SOURCE[0]%/*}/../../scripts/common.sh}"
# shellcheck source=/dev/null
source "${COMMON_SCRIPT}"
readonly COMMON_SCRIPT
require_configuration_variables NATIVE_LIBRARY_PATH

readonly STEAM_RESTART_DELAY_SECONDS=1
# Valve's client uses this status to request an in-process relaunch.
readonly STEAM_RESTART_EXIT_STATUS=42
readonly -a X86_OVERLAY_LINKS=(
  bin32
  bin64
)

# Steam updates recreate x86 overlay links under ~/.steam. Preloading those
# libraries into the ARM64 launch shell fails before Proton can start. The x86
# client recreates its links when that backend is launched again.
disable_x86_overlay_preloads() {
  local link_name

  for link_name in "${X86_OVERLAY_LINKS[@]}"; do
    if [[ -L "${HOME}/.steam/${link_name}" ]]; then
      rm -f -- "${HOME}/.steam/${link_name}"
    fi
  done
}

main() {
  local candidate
  local data_home="${XDG_DATA_HOME:-${HOME}/.local/share}"
  local -a path_entries=("${GUEST_PATH_ENTRIES[@]}")
  local -a library_directories
  local runtime_tools_directory=
  local steamapps_directory="${data_home}/Steam/steamapps/common"
  local status
  local steam_native_directory
  local usage
  local relative_path

  printf -v usage '%s%s' \
    'usage: steam-asahi-arm64-guest [--steam] command ' \
    '[arguments...]'

  (( $# > 0 )) || die "${usage}"

  # The ARM client invokes this bundled service by its unqualified name.
  for relative_path in "${ARM64_RUNTIME_TOOL_RELATIVE_DIRECTORIES[@]}"; do
    candidate="${steamapps_directory}/${relative_path}"
    if [[ -x "${candidate}/steam-runtime-launcher-service" ]]; then
      runtime_tools_directory=${candidate}
      break
    fi
  done
  if [[ -n "${runtime_tools_directory}" ]]; then
    path_entries+=("${runtime_tools_directory}")
  fi
  prepend_colon_path PATH "${path_entries[@]}"
  steam_native_directory="${data_home}/Steam/${ARM64_CLIENT_DIRECTORY_NAME}"

  # Prefer Valve's coherent client runtime over same-SONAME Nix libraries, then
  # fall back to the system Asahi graphics stack and declared native libraries.
  library_directories=(
    "${steam_native_directory}"
    "${steam_native_directory}/libs"
    "${OPENGL_DRIVER_ROOT}/lib"
    "${NATIVE_LIBRARY_PATH}"
  )
  prepend_colon_path LD_LIBRARY_PATH "${library_directories[@]}"
  export PULSE_SERVER="unix:/run/user/${EUID}/pulse/native"
  export SDL_AUDIODRIVER=pulseaudio
  prepend_colon_path XDG_DATA_DIRS "${GUEST_DATA_DIRECTORIES[@]}"
  export_default_environment COMMON_DRIVER_ENVIRONMENT
  export_default_environment ARM64_DRIVER_ENVIRONMENT
  export LC_ALL="${C_LOCALE}"
  export LANG="${C_LOCALE}"
  export LOCALE_ARCHIVE="${LOCALE_ARCHIVE_PATH}"
  export TZDIR="${TZDATA_DIRECTORY}"
  unset -v GIO_EXTRA_MODULES

  if [[ "$1" == '--steam' ]]; then
    shift
    (( $# > 0 )) || die 'the --steam option requires a command'

    while true; do
      disable_x86_overlay_preloads
      if "$@"; then
        status=0
      else
        status=$?
      fi

      if (( status != STEAM_RESTART_EXIT_STATUS )); then
        return "${status}"
      fi

      printf '%s%s\n' \
        'Steam requested a client restart; relaunching inside the existing ' \
        'microVM...'
      sleep "${STEAM_RESTART_DELAY_SECONDS}"
    done
  fi

  exec "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  shopt -s array_expand_once
  main "$@"
fi
