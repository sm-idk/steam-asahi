#!/usr/bin/env bash
# shellcheck shell=bash
#
# Prepares the FEX and Steam state, then launches Steam through muvm and FEX.
# Nix supplies Bash 5.3; `${ command; }` captures output without a subshell.

set -o errexit
set -o nounset
set -o pipefail

: "${COMMON_SCRIPT:=${BASH_SOURCE[0]%/*}/../../scripts/common.sh}"
# shellcheck source=/dev/null
source "${COMMON_SCRIPT}"
readonly COMMON_SCRIPT

readonly -a REQUIRED_CONFIGURATION_VARIABLES=(
  ENV_BIN
  FEX_BASH
  FEX_DIAGNOSTIC_SCRIPT
  FEX_ROOTFS_FETCHER
  FEX_STEAM_SCRIPT
  INIT_SCRIPT
  MUVM
  MUVM_HOST_MOUNT
  MUVM_PATH
  STEAM_BOOTSTRAP
  YAD
)
require_configuration_variables "${REQUIRED_CONFIGURATION_VARIABLES[@]}"
# These values implement interfaces provided by the sourced common module.
: "${ENV_BIN}" "${YAD}"

readonly -a EXTRA_ENVIRONMENT_ARGS
readonly -a MUVM_MEMORY_ARGS
readonly -a MUVM_NETWORK_ARGS
readonly -a MUVM_VRAM_ARGS

# FEXBash passes nonempty argv to `/bin/sh -c`. This command string makes the
# remaining argv actual arguments to our non-executable store script.
readonly FEX_BASH_COMMAND='exec /bin/bash "$@"'
readonly FEX_ROOTFS_CONFIG_PATTERN=\
'"RootFS"[[:space:]]*:[[:space:]]*"[^"]+"'
readonly FEX_ROOTFS_DISTRIBUTION=Fedora
readonly FEX_ROOTFS_DISTRIBUTION_VERSION=44
readonly FEX_ROOTFS_DOWNLOAD_SIZE='~1.3 GB'
readonly -a FEX_ROOTFS_EXTENSIONS=(
  ero
  img
  sqsh
)
readonly -a FEX_ROOTFS_FETCH_ARGS=(
  --assume-yes
  "--distro-name=${FEX_ROOTFS_DISTRIBUTION}"
  "--distro-version=${FEX_ROOTFS_DISTRIBUTION_VERSION}"
  --distro-list-first
  --as-is
)
readonly -a MUVM_GUEST_PATH_ENTRIES=(
  "${WRAPPERS_BIN_DIRECTORY}"
  "${MUVM_PATH}"
  "${GUEST_PATH_ENTRIES[@]}"
)
join_colon_values GUEST_PATH "${MUVM_GUEST_PATH_ENTRIES[@]}"
readonly GUEST_PATH
readonly -a MUVM_BASE_ARGS=(
  --emu=fex
  --gpu-mode=drm
  "${MUVM_MEMORY_ARGS[@]}"
  "${MUVM_VRAM_ARGS[@]}"
  "${MUVM_NETWORK_ARGS[@]}"
  --execute-pre "${INIT_SCRIPT}"
  --interactive
  -e "PATH=${GUEST_PATH}"
)
readonly SPLASH_HOLD_SECONDS=10

is_fex_rootfs() {
  local extension
  local path=$1

  [[ -e "${path}" ]] || return 1
  [[ -d "${path}" ]] && return 0
  for extension in "${FEX_ROOTFS_EXTENSIONS[@]}"; do
    [[ "${path}" == *."${extension}" ]] && return 0
  done
  return 1
}

# muvm exposes the host filesystem at this mount point inside its guest. A
# second muvm cannot start there because nested KVM is unavailable.
reject_muvm_guest() {
  [[ ! -d "${MUVM_HOST_MOUNT}" ]] || die \
    'Already inside a muvm guest. Exit FEXBash and run steam-asahi on the host.'
}

# Detects an existing FEX rootfs across legacy and XDG layouts, downloading a
# pinned distro image only when no usable configuration exists.
ensure_fex_rootfs() {
  local config_home="${XDG_CONFIG_HOME:-${HOME}/.config}"
  local data_home="${XDG_DATA_HOME:-${HOME}/.local/share}"
  local fex_config
  local fex_config_contents
  local -i fex_configured=0
  local fex_data_directory
  local rootfs_path

  # FEX honors ~/.fex-emu only when it already exists; otherwise it uses XDG
  # data and config directories.
  if [[ -d "${HOME}/.fex-emu" ]]; then
    fex_data_directory="${HOME}/.fex-emu"
    fex_config="${HOME}/.fex-emu/Config.json"
  else
    fex_data_directory="${data_home}/fex-emu"
    fex_config="${config_home}/fex-emu/Config.json"
  fi

  if [[ -d "${fex_data_directory}/RootFS" ]]; then
    for rootfs_path in "${fex_data_directory}"/RootFS/*; do
      if is_fex_rootfs "${rootfs_path}"; then
        fex_configured=1
        break
      fi
    done
  fi

  if (( ! fex_configured )) && [[ -r "${fex_config}" ]]; then
    fex_config_contents=$(<"${fex_config}")
    if [[ "${fex_config_contents}" =~ ${FEX_ROOTFS_CONFIG_PATTERN} ]]; then
      fex_configured=1
    fi
  fi

  if (( ! fex_configured )); then
    printf \
      'FEX rootfs not found. Downloading %s %s rootfs...\n%s\n' \
      "${FEX_ROOTFS_DISTRIBUTION}" \
      "${FEX_ROOTFS_DISTRIBUTION_VERSION}" \
      "This is a one-time setup (${FEX_ROOTFS_DOWNLOAD_SIZE} download)."
    "${FEX_ROOTFS_FETCHER}" "${FEX_ROOTFS_FETCH_ARGS[@]}" \
      || die 'FEX rootfs download failed; run FEXRootFSFetcher manually.'
  fi
}

show_splash() {
  local cef_log="${HOME}/.local/share/Steam/logs/cef_log.txt"

  show_startup_splash \
    "${cef_log}" \
    "${SPLASH_HOLD_SECONDS}" \
    'Starting Steam (microVM + FEX)...'
}

# Installs the immutable bootstrap into user-writable state exactly once while
# preserving the Steam client's subsequent self-updates.
install_steam_bootstrap() {
  local data_directory=$1
  local marker="${data_directory}/bootstrap-installed"

  if [[ -f "${marker}" \
    && -f "${data_directory}/steam-launcher/bin_steam.sh" ]]; then
    return
  fi

  printf '%s\n' 'Setting up Steam bootstrap...'
  mkdir -p -- "${data_directory}"
  cp --archive --no-target-directory -- \
    "${STEAM_BOOTSTRAP}" \
    "${data_directory}/steam-launcher"
  chmod -RP u+rwX -- "${data_directory}/steam-launcher"
  write_managed_value "${marker}" ok
  printf '%s\n' 'Steam bootstrap ready.'
}

run_fex_diagnostic() {
  local command=$1

  run_in_clean_environment \
    "${MUVM}" \
    "${MUVM_BASE_ARGS[@]}" \
    -- \
    "${FEX_BASH}" "${FEX_BASH_COMMAND}" steam-asahi-fex \
    "${FEX_DIAGNOSTIC_SCRIPT}" "${command}"
}

run_steam() {
  local data_directory=$1
  shift

  printf '%s\n' 'Launching Steam via muvm + FEX...'
  run_in_clean_environment \
    "${MUVM}" \
    "${MUVM_BASE_ARGS[@]}" \
    -e "PRESSURE_VESSEL_FILESYSTEMS_RO=${PRESSURE_VESSEL_FILESYSTEMS_RO}" \
    -e "STEAM_ASAHI_GUEST_UID=${EUID}" \
    "${EXTRA_ENVIRONMENT_ARGS[@]}" \
    -- \
    "${FEX_BASH}" "${FEX_BASH_COMMAND}" steam-asahi-fex \
    "${FEX_STEAM_SCRIPT}" \
    "${data_directory}/steam-launcher/bin_steam.sh" \
    "${STEAM_CLIENT_ARGS[@]}" \
    "$@"
}

main() {
  local data_home="${XDG_DATA_HOME:-${HOME}/.local/share}"
  local data_directory="${data_home}/steam-asahi"
  # None of the installation globs depend on lexical order.
  local -r GLOBSORT=nosort

  (( EUID != 0 )) || die 'Do not run steam-asahi as root'
  reject_muvm_guest
  ensure_fex_rootfs

  if [[ "${1:-}" == '--fex' ]]; then
    shift
    (( $# == 1 )) || die "usage: steam-asahi --fex '<command>'"
    run_fex_diagnostic "$1"
  fi

  warn_missing_audio_socket
  show_splash
  install_steam_bootstrap "${data_directory}"
  run_steam "${data_directory}" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  shopt -s inherit_errexit nullglob
  main "$@"
fi
