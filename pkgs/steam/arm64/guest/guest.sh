#!/usr/bin/env bash
# shellcheck shell=bash
#
# Configures the ARM64 Steam guest environment and runs the requested command

set -o errexit
set -o nounset
set -o pipefail

: "${COMMON_SCRIPT:=${BASH_SOURCE[0]%/*}/../../../../src/guest/common.sh}"
# shellcheck source=/dev/null
source "${COMMON_SCRIPT}"
readonly COMMON_SCRIPT
require_configuration_variables NATIVE_LIBRARY_PATH

readonly STEAM_RESTART_DELAY_SECONDS=1
# Valve uses this status to request a relaunch in the existing microVM
readonly STEAM_RESTART_EXIT_STATUS=42
readonly -a X86_OVERLAY_LINKS=(bin32 bin64)

# Steam updates recreate x86 overlay links, which cannot load into ARM shells
disable_x86_overlay_preloads() {
  local link_name

  for link_name in "${X86_OVERLAY_LINKS[@]}"; do
    if [[ -L "${HOME}/.steam/${link_name}" ]]; then
      rm --force -- "${HOME}/.steam/${link_name}" || return
    fi
  done
}

# Valve's helper assumes host CPU IDs 2-6 and leaves its path unquoted;
# retain muvm's affinity because it numbers guest CPUs from zero
#
# Reapply only the known upstream command repair after client updates
# shellcheck disable=SC2016
repair_webhelper_script() {
  local client_directory=$1
  local helper_script="${client_directory}/steamwebhelper.sh"
  local script_contents
  local temporary_path
  local old_command='exec taskset 0x7c $(pwd)/steamwebhelper "$@"'
  local new_command='exec ./steamwebhelper "$@"'
  local original_cd='cd $SCRIPTPATH'
  local replacement_cd='cd -- "$SCRIPTPATH" || exit'

  [[ -f "${helper_script}" ]] || return 0
  script_contents=$(<"${helper_script}")
  [[ "${script_contents}" == *"${old_command}"* ]] || return 0
  script_contents=${script_contents/"${old_command}"/"${new_command}"}
  script_contents=${script_contents/"${original_cd}"/"${replacement_cd}"}

  create_managed_temporary_path temporary_path "${helper_script}" || return
  if ! printf '%s\n' "${script_contents}" >"${temporary_path}" \
    || ! chmod --reference="${helper_script}" -- "${temporary_path}"; then
    rm --force -- "${temporary_path}"
    return 1
  fi
  commit_managed_temporary_path "${temporary_path}" "${helper_script}"
}

# Some codec archives ship unversioned files with versioned ELF SONAMEs,
# so populate their missing aliases without changing the guest's library cache
repair_client_library_links() {
  local client_directory=$1

  [[ -d "${client_directory}/libs" ]] || return 0
  /usr/sbin/ldconfig -n "${client_directory}" "${client_directory}/libs"
}

# Valve's ARM FFmpeg 8 build references X11 without a DT_NEEDED entry; declare
# it locally so dlopen does not depend on a prior global X11 load
repair_client_library_dependencies() {
  local library_path="$1/libavutil.so.60"
  local needed_libraries
  local temporary_path

  [[ -f "${library_path}" ]] || return 0
  needed_libraries=$(patchelf --print-needed "${library_path}") || return
  if [[ $'\n'"${needed_libraries}"$'\n' == *$'\nlibX11.so.6\n'* ]]; then
    return 0
  fi

  create_managed_temporary_path temporary_path "${library_path}" || return
  if ! cp --preserve=mode -- "${library_path}" "${temporary_path}" \
    || ! patchelf --add-needed libX11.so.6 "${temporary_path}"; then
    rm --force -- "${temporary_path}"
    return 1
  fi
  commit_managed_temporary_path "${temporary_path}" "${library_path}"
}

main() {
  local data_home="${XDG_DATA_HOME:-${HOME}/.local/share}"
  local -a path_entries=()
  local -a library_directories
  local steamapps_directory="${data_home}/Steam/steamapps/common"
  local status
  local steam_native_directory
  local usage
  local relative_path

  printf -v usage '%s%s' \
    'usage: steam-asahi-arm64-guest [--steam] command ' \
    '[arguments...]'

  (($# > 0)) || die "${usage}"

  # Steam can install the runtime while running, so include its future paths
  # before the client starts searching for the unqualified launcher service
  for relative_path in "${ARM64_RUNTIME_TOOL_RELATIVE_DIRECTORIES[@]}"; do
    path_entries+=("${steamapps_directory}/${relative_path}")
  done
  configure_guest_environment "${EUID}" "${path_entries[@]}"
  steam_native_directory="${data_home}/Steam/${ARM64_CLIENT_DIRECTORY_NAME}"

  # Prefer Valve's coherent client runtime over same-SONAME Nix libraries, then
  # fall back to the system Asahi graphics stack and declared native libraries
  library_directories=(
    "${steam_native_directory}"
    "${steam_native_directory}/libs"
    "${OPENGL_DRIVER_ROOT}/lib"
    "${NATIVE_LIBRARY_PATH}"
  )
  prepend_colon_path LD_LIBRARY_PATH "${library_directories[@]}"
  export_default_environment ARM64_DRIVER_ENVIRONMENT

  if [[ "$1" == '--forward' ]]; then
    shift
    (($# > 0)) || die 'the --forward option requires a command'
    # Another client owns the mutable installation; only send it the argv
    exec "$@"
  fi

  if [[ "$1" == '--steam' ]]; then
    shift
    (($# > 0)) || die 'the --steam option requires a command'

    while true; do
      disable_x86_overlay_preloads
      repair_webhelper_script "${steam_native_directory}"
      repair_client_library_links "${steam_native_directory}"
      repair_client_library_dependencies "${steam_native_directory}"
      if "$@"; then
        status=0
      else
        status=$?
      fi

      if ((status != STEAM_RESTART_EXIT_STATUS)); then
        return "${status}"
      fi

      printf '%s%s\n' \
        'Steam requested a client restart; relaunching inside the existing ' \
        'microVM...'
      sleep "${STEAM_RESTART_DELAY_SECONDS}"
    done
  fi

  repair_client_library_links "${steam_native_directory}"
  repair_client_library_dependencies "${steam_native_directory}"
  exec "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  shopt -s array_expand_once
  main "$@"
fi
