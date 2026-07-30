#!/usr/bin/env bash
# shellcheck shell=bash
#
# Installs the managed ARM64 Steam state and launches it through muvm.

set -o errexit
set -o nounset
set -o pipefail

: "${CLIENT_BOOTSTRAP:?internal configuration was not injected}"
: "${CLIENT_UPDATE_CHANNEL:?internal configuration was not injected}"
: "${COMPATIBILITY_TOOL_DIRECTORY:?internal configuration was not injected}"
: "${COMPATIBILITY_TOOL_VDF:?internal configuration was not injected}"
: "${DISPLAY_NAME:?internal configuration was not injected}"
: "${ENV_BIN:?internal configuration was not injected}"
: "${GUEST_LAUNCHER:?internal configuration was not injected}"
: "${HOST_LIBRARIES:?internal configuration was not injected}"
: "${INIT_SCRIPT:?internal configuration was not injected}"
: "${MUVM:?internal configuration was not injected}"
: "${PROTON_DIRECTORY:?internal configuration was not injected}"
: "${PROTON_RUNNER:?internal configuration was not injected}"
: "${PROTON_WRAPPER:?internal configuration was not injected}"
: "${RUNTIME_APP_ID:?internal configuration was not injected}"
: "${RUNTIME_DIRECTORY:?internal configuration was not injected}"
: "${TOOL_MANIFEST:?internal configuration was not injected}"
: "${YAD:?internal configuration was not injected}"

readonly CLIENT_BOOTSTRAP
readonly CLIENT_UPDATE_CHANNEL
readonly COMPATIBILITY_TOOL_DIRECTORY
readonly COMPATIBILITY_TOOL_VDF
readonly DISPLAY_NAME
readonly ENV_BIN
readonly GUEST_LAUNCHER
readonly HOST_LIBRARIES
readonly INIT_SCRIPT
readonly -a MEMORY_ARGS
readonly MUVM
readonly -a NETWORK_ARGS
readonly PROTON_DIRECTORY
readonly PROTON_RUNNER
readonly PROTON_WRAPPER
readonly RUNTIME_APP_ID
readonly RUNTIME_DIRECTORY
readonly TOOL_MANIFEST
readonly -a VRAM_ARGS
readonly YAD

readonly -a CLEAN_ENVIRONMENT_ARGS=(
  -u BASH_ENV
  -u ENV
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

readonly STEAM_DIRECTORY="${XDG_DATA_HOME:-${HOME}/.local/share}/Steam"
readonly CLIENT_DIRECTORY="${STEAM_DIRECTORY}/steamrtarm64"
readonly COMPATIBILITY_DIRECTORY=\
"${STEAM_DIRECTORY}/compatibilitytools.d/${COMPATIBILITY_TOOL_DIRECTORY}"
readonly MAX_PROTON_LOG_SIZE_BYTES=1048576
readonly PROTON_DIRECTORY_PATH=\
"${STEAM_DIRECTORY}/steamapps/common/${PROTON_DIRECTORY}"
readonly RUNTIME_DIRECTORY_PATH=\
"${STEAM_DIRECTORY}/steamapps/common/${RUNTIME_DIRECTORY}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

warn_missing_audio_socket() {
  local runtime_directory="${XDG_RUNTIME_DIR:-/run/user/${EUID}}"
  local socket_path="${runtime_directory}/pulse/native"

  [[ -S "${socket_path}" ]] && return
  printf 'WARNING: PulseAudio socket not found at %s.\n' \
    "${socket_path}" >&2
  printf '%s\n' \
    'Steam audio needs PipeWire Pulse or PulseAudio on the host.' \
    'Enable one of them and restart Steam Asahi.' >&2
}

run_guest() {
  exec "${ENV_BIN}" \
    "${CLEAN_ENVIRONMENT_ARGS[@]}" \
    "${MUVM}" \
    --gpu-mode=drm \
    "${MEMORY_ARGS[@]}" \
    "${VRAM_ARGS[@]}" \
    "${NETWORK_ARGS[@]}" \
    --execute-pre "${INIT_SCRIPT}" \
    --interactive \
    -e "PRESSURE_VESSEL_FILESYSTEMS_RO=/nix:/run/opengl-driver" \
    -e "STEAM_ASAHI_GUEST_HOME=${HOME}" \
    -e "STEAM_ASAHI_GUEST_UID=${EUID}" \
    -- \
    "${GUEST_LAUNCHER}" "$@"
}

install_managed_file() {
  local destination_directory
  local temporary_path
  local destination=$2
  local mode=$3
  local source_path=$1

  destination_directory=$(dirname -- "${destination}")
  temporary_path=$(mktemp \
    --tmpdir="${destination_directory}" \
    ".$(basename -- "${destination}").XXXXXX")

  if ! install -m "${mode}" -- "${source_path}" "${temporary_path}"; then
    rm -f -- "${temporary_path}"
    return 1
  fi
  if ! mv -f -- "${temporary_path}" "${destination}"; then
    rm -f -- "${temporary_path}"
    return 1
  fi
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

# Repairs a missing or partial client bootstrap while retaining mutable files
# written by Steam itself.
install_client_bootstrap() {
  if [[ -x "${CLIENT_DIRECTORY}/steam" ]]; then
    return
  fi

  printf '%s\n' 'Installing the pinned ARM64 Steam beta bootstrap...'
  mkdir -p -- "${CLIENT_DIRECTORY}"
  cp -a -- "${CLIENT_BOOTSTRAP}/." "${CLIENT_DIRECTORY}/"
  chmod -R u+rwX -- "${CLIENT_DIRECTORY}"
}

configure_steam_state() {
  local beta_file="${STEAM_DIRECTORY}/package/beta"
  local link_name

  mkdir -p -- "$(dirname -- "${beta_file}")" "${HOME}/.steam"
  if [[ ! -f "${beta_file}" \
    || "$(<"${beta_file}")" != "${CLIENT_UPDATE_CHANNEL}" ]]; then
    write_managed_value "${beta_file}" "${CLIENT_UPDATE_CHANNEL}"
  fi

  for link_name in steam root; do
    if [[ ! -e "${HOME}/.steam/${link_name}" \
      && ! -L "${HOME}/.steam/${link_name}" ]]; then
      ln -s -- "${STEAM_DIRECTORY}" "${HOME}/.steam/${link_name}"
    fi
  done

  if [[ ! -e "${HOME}/.steam/sdkarm64" \
    && ! -L "${HOME}/.steam/sdkarm64" ]]; then
    ln -s -- "${STEAM_DIRECTORY}/linuxarm64" "${HOME}/.steam/sdkarm64"
  fi
}

# Materializes the small managed compatibility-tool wrapper only after both
# Valve-managed payloads are installed, then bounds its diagnostic log.
install_proton_integration() {
  local log_path="${COMPATIBILITY_DIRECTORY}/steam-asahi-proton.log"
  local log_size

  if [[ -x "${PROTON_DIRECTORY_PATH}/proton" \
    && -x "${RUNTIME_DIRECTORY_PATH}/_v2-entry-point" ]]; then
    mkdir -p -- "${COMPATIBILITY_DIRECTORY}"
    install_managed_file \
      "${COMPATIBILITY_TOOL_VDF}" \
      "${COMPATIBILITY_DIRECTORY}/compatibilitytool.vdf" \
      0644
    install_managed_file \
      "${TOOL_MANIFEST}" \
      "${COMPATIBILITY_DIRECTORY}/toolmanifest.vdf" \
      0644
    install_managed_file \
      "${PROTON_RUNNER}" \
      "${COMPATIBILITY_DIRECTORY}/run-proton" \
      0755
    install_managed_file \
      "${PROTON_WRAPPER}" \
      "${COMPATIBILITY_DIRECTORY}/steam-asahi-proton" \
      0755
    ln -sfn -- "${PROTON_DIRECTORY_PATH}" "${COMPATIBILITY_DIRECTORY}/proton"
    ln -sfn -- "${RUNTIME_DIRECTORY_PATH}" "${COMPATIBILITY_DIRECTORY}/runtime"
    ln -sfn -- "${HOST_LIBRARIES}" "${COMPATIBILITY_DIRECTORY}/host-libs"
    rm -f -- "${STEAM_DIRECTORY}/compatibilitytools.d/steam-asahi-arm64.vdf"

    if log_size=$(stat -c %s -- "${log_path}" 2>/dev/null) \
      && (( log_size > MAX_PROTON_LOG_SIZE_BYTES )); then
      # Diagnostic-log rotation must not prevent Steam from launching if two
      # launchers race or the log disappears between stat(2) and rename(2).
      mv -f -- "${log_path}" "${log_path}.old" 2>/dev/null || true
    fi
  elif [[ -x "${PROTON_DIRECTORY_PATH}/proton" ]]; then
    printf '%s is installed, but %s (AppID %s) is missing.\n' \
      "${DISPLAY_NAME}" \
      'Steam Linux Runtime 4.0 - Arm64' \
      "${RUNTIME_APP_ID}" >&2
  fi
}

# Displays a bounded startup dialog without delaying or owning the Steam
# process. The background watcher always removes its temporary marker.
show_splash() {
  local cef_log="${STEAM_DIRECTORY}/logs/cef_log.txt"
  local -i attempt
  local launcher_pid=$$
  local marker
  local splash_pid

  [[ "${STEAM_ASAHI_NO_SPLASH:-0}" == 1 || -t 0 || -t 1 ]] && return

  marker=$(mktemp)
  "${YAD}" --no-buttons --center --borders=16 \
    --title='Steam' --window-icon=steam \
    --text='Starting native ARM64 Steam (4K-page microVM)...' &
  splash_pid=$!

  (
    trap 'kill "${splash_pid}" 2>/dev/null || true; rm -f -- "${marker}"' EXIT

    for (( attempt = 0; attempt < 180; attempt += 1 )); do
      kill -0 "${launcher_pid}" 2>/dev/null || break
      [[ -f "${cef_log}" && "${cef_log}" -nt "${marker}" ]] && break
      sleep 1
    done

    sleep 5
  ) &
}

main() {
  (( EUID != 0 )) || die 'Do not run steam-asahi as root'

  if [[ "${1:-}" == '--guest' ]]; then
    shift
    (( $# > 0 )) || die 'usage: steam-asahi --guest command [arguments...]'
    run_guest "$@"
  fi

  warn_missing_audio_socket
  install_client_bootstrap
  configure_steam_state
  install_proton_integration
  show_splash

  printf '%s\n' 'Launching native ARM64 Steam via muvm...'
  run_guest --steam "${CLIENT_DIRECTORY}/steam" -cef-force-occlusion "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
