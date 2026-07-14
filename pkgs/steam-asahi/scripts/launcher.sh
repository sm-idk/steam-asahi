#!/usr/bin/env bash
# shellcheck shell=bash
#
# Prepares the FEX and Steam state, then launches Steam through muvm and FEX.

set -o errexit
set -o nounset
set -o pipefail

: "${ENV_BIN:?internal configuration was not injected}"
: "${FEX_BASH:?internal configuration was not injected}"
: "${FEX_DIAGNOSTIC_SCRIPT:?internal configuration was not injected}"
: "${FEX_ROOTFS_FETCHER:?internal configuration was not injected}"
: "${FEX_STEAM_SCRIPT:?internal configuration was not injected}"
: "${INIT_SCRIPT:?internal configuration was not injected}"
: "${MUVM:?internal configuration was not injected}"
: "${MUVM_HOST_MOUNT:?internal configuration was not injected}"
: "${MUVM_PATH:?internal configuration was not injected}"
: "${STEAM_BOOTSTRAP:?internal configuration was not injected}"
: "${YAD:?internal configuration was not injected}"

readonly ENV_BIN
readonly -a EXTRA_ENVIRONMENT_ARGS
readonly FEX_BASH
readonly FEX_DIAGNOSTIC_SCRIPT
readonly FEX_ROOTFS_FETCHER
readonly FEX_STEAM_SCRIPT
readonly INIT_SCRIPT
readonly MUVM
readonly MUVM_HOST_MOUNT
readonly -a MUVM_MEMORY_ARGS
readonly -a MUVM_NETWORK_ARGS
readonly MUVM_PATH
readonly -a MUVM_VRAM_ARGS
readonly STEAM_BOOTSTRAP
readonly YAD

readonly -a CLEAN_ENVIRONMENT_ARGS=(
  -u LANGUAGE
  -u LC_ADDRESS
  -u LC_COLLATE
  -u LC_CTYPE
  -u LC_IDENTIFICATION
  -u LC_MEASUREMENT
  -u LC_MESSAGES
  -u LC_MONETARY
  -u LC_NAME
  -u LC_NUMERIC
  -u LC_PAPER
  -u LC_TELEPHONE
  -u LC_TIME
  LANG=C.UTF-8
  LC_ALL=C.UTF-8
)

# FEXBash passes nonempty argv to `/bin/sh -c`. Use a command string that
# makes the remaining argv actual arguments to our non-executable store script.
readonly FEX_BASH_COMMAND='exec /bin/bash "$@"'

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
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
  local fex_configured=false
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
      [[ -e "${rootfs_path}" ]] || continue
      case "${rootfs_path}" in
        *.ero | *.sqsh | *.img)
          fex_configured=true
          break
          ;;
      esac
      if [[ -d "${rootfs_path}" ]]; then
        fex_configured=true
        break
      fi
    done
  fi

  if [[ "${fex_configured}" == 'false' && -f "${fex_config}" ]]; then
    if grep -qE \
      '"RootFS"[[:space:]]*:[[:space:]]*"[^"]+"' \
      "${fex_config}" 2>/dev/null; then
      fex_configured=true
    fi
  fi

  if [[ "${fex_configured}" == 'false' ]]; then
    printf '%s\n' \
      'FEX rootfs not found. Downloading Fedora 43 rootfs...' \
      'This is a one-time setup (~1.3GB download).'
    "${FEX_ROOTFS_FETCHER}" \
      --assume-yes \
      --distro-name=Fedora \
      --distro-version=43 \
      --distro-list-first \
      --as-is \
      || die 'FEX rootfs download failed; run FEXRootFSFetcher manually.'
  fi
}

# Displays a bounded startup dialog without delaying or owning the Steam
# process. The background watcher always removes its temporary marker.
show_splash() {
  local cef_log="${HOME}/.local/share/Steam/logs/cef_log.txt"
  local -i attempt
  local launcher_pid=$$
  local marker
  local splash_pid
  local ui_started=false

  [[ "${STEAM_ASAHI_NO_SPLASH:-0}" == 1 || -t 0 || -t 1 ]] && return

  marker=$(mktemp)
  "${YAD}" --no-buttons --center --borders=16 \
    --title='Steam' --window-icon=steam \
    --text='Starting Steam (microVM + FEX)...' &
  splash_pid=$!

  (
    trap 'kill "${splash_pid}" 2>/dev/null || true; rm -f -- "${marker}"' EXIT

    for (( attempt = 0; attempt < 180; attempt += 1 )); do
      kill -0 "${launcher_pid}" 2>/dev/null || break
      if [[ -f "${cef_log}" && "${cef_log}" -nt "${marker}" ]]; then
        ui_started=true
        break
      fi
      sleep 1
    done

    [[ "${ui_started}" == 'true' ]] && sleep 10
  ) &
}

write_managed_value() {
  local destination=$1
  local temporary_path
  local value=$2

  temporary_path=$(mktemp \
    --tmpdir="$(dirname -- "${destination}")" \
    ".$(basename -- "${destination}").XXXXXX")
  if ! printf '%s\n' "${value}" >"${temporary_path}"; then
    rm -f -- "${temporary_path}"
    return 1
  fi
  if ! mv -f -- "${temporary_path}" "${destination}"; then
    rm -f -- "${temporary_path}"
    return 1
  fi
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
  cp -a -- "${STEAM_BOOTSTRAP}" "${data_directory}/"
  chmod -R u+rwX -- "${data_directory}/steam-launcher"
  write_managed_value "${marker}" ok
  printf '%s\n' 'Steam bootstrap ready.'
}

run_fex_diagnostic() {
  local command=$1

  exec "${ENV_BIN}" \
    "${CLEAN_ENVIRONMENT_ARGS[@]}" \
    "${MUVM}" \
    --gpu-mode=drm \
    "${MUVM_MEMORY_ARGS[@]}" \
    "${MUVM_VRAM_ARGS[@]}" \
    "${MUVM_NETWORK_ARGS[@]}" \
    --execute-pre "${INIT_SCRIPT}" \
    --interactive \
    -e "PATH=/run/wrappers/bin:${MUVM_PATH}:/usr/local/bin:/usr/bin:/bin" \
    -- \
    "${FEX_BASH}" "${FEX_BASH_COMMAND}" steam-asahi-fex \
    "${FEX_DIAGNOSTIC_SCRIPT}" "${command}"
}

run_steam() {
  local data_directory=$1
  shift

  printf '%s\n' 'Launching Steam via muvm + FEX...'
  exec "${ENV_BIN}" \
    "${CLEAN_ENVIRONMENT_ARGS[@]}" \
    "${MUVM}" \
    --gpu-mode=drm \
    "${MUVM_MEMORY_ARGS[@]}" \
    "${MUVM_VRAM_ARGS[@]}" \
    "${MUVM_NETWORK_ARGS[@]}" \
    --execute-pre "${INIT_SCRIPT}" \
    --interactive \
    -e "PATH=/run/wrappers/bin:${MUVM_PATH}:/usr/local/bin:/usr/bin:/bin" \
    -e 'PRESSURE_VESSEL_FILESYSTEMS_RO=/nix:/run/opengl-driver' \
    -e "STEAM_ASAHI_GUEST_UID=${EUID}" \
    "${EXTRA_ENVIRONMENT_ARGS[@]}" \
    -- \
    "${FEX_BASH}" "${FEX_BASH_COMMAND}" steam-asahi-fex \
    "${FEX_STEAM_SCRIPT}" \
    "${data_directory}/steam-launcher/bin_steam.sh" \
    -cef-force-occlusion \
    "$@"
}

main() {
  local data_home="${XDG_DATA_HOME:-${HOME}/.local/share}"
  local data_directory="${data_home}/steam-asahi"

  (( EUID != 0 )) || die 'Do not run steam-asahi as root'
  reject_muvm_guest
  ensure_fex_rootfs

  if [[ "${1:-}" == '--fex' ]]; then
    shift
    (( $# == 1 )) || die "usage: steam-asahi --fex '<command>'"
    run_fex_diagnostic "${1}"
  fi

  show_splash
  install_steam_bootstrap "${data_directory}"
  run_steam "${data_directory}" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
