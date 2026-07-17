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
if [[ ! -v CUSTOM_STEAM_HOME_DIR ]]; then
  printf '%s\n' \
    'ERROR: internal custom Steam HOME configuration was not injected' >&2
  exit 1
fi
: "${DEFAULT_STEAM_HOME_DIR:?internal configuration was not injected}"
: "${DISPLAY_NAME:?internal configuration was not injected}"
: "${ENV_BIN:?internal configuration was not injected}"
: "${FLOCK:?internal configuration was not injected}"
: "${GUEST_LAUNCHER:?internal configuration was not injected}"
: "${HOST_LIBRARIES:?internal configuration was not injected}"
: "${INIT_SCRIPT:?internal configuration was not injected}"
: "${MUVM:?internal configuration was not injected}"
: "${PROTON_DIRECTORY:?internal configuration was not injected}"
: "${PROTON_CONFIGURATOR:?internal configuration was not injected}"
: "${PROTON_RUNNER:?internal configuration was not injected}"
: "${PROTON_TOOL_NAME:?internal configuration was not injected}"
: "${PROTON_WRAPPER:?internal configuration was not injected}"
: "${RUNTIME_APP_ID:?internal configuration was not injected}"
: "${RUNTIME_DIRECTORY:?internal configuration was not injected}"
: "${TOOL_MANIFEST:?internal configuration was not injected}"
: "${YAD:?internal configuration was not injected}"

readonly CLIENT_BOOTSTRAP
readonly CLIENT_UPDATE_CHANNEL
readonly COMPATIBILITY_TOOL_DIRECTORY
readonly COMPATIBILITY_TOOL_VDF
readonly CUSTOM_STEAM_HOME_DIR
readonly DEFAULT_STEAM_HOME_DIR
readonly DISPLAY_NAME
readonly ENV_BIN
readonly FLOCK
readonly GUEST_LAUNCHER
readonly HOST_LIBRARIES
readonly INIT_SCRIPT
readonly -a MEMORY_ARGS
readonly MUVM
readonly -a NETWORK_ARGS
readonly PROTON_DIRECTORY
readonly PROTON_CONFIGURATOR
readonly PROTON_RUNNER
readonly PROTON_TOOL_NAME
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
readonly MAX_PROTON_LOG_SIZE_BYTES=1048576

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# Resolves the isolated state only when the executable enters main. Keeping
# this out of global scope avoids rewriting a sourcing shell's HOME/XDG paths.
initialize_steam_home() {
  local steam_home_directory

  SOURCE_HOME="${HOME}"
  SOURCE_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
  SOURCE_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
  steam_home_directory="${CUSTOM_STEAM_HOME_DIR:-${DEFAULT_STEAM_HOME_DIR}}"
  if [[ "${steam_home_directory}" == /* ]]; then
    HOME="${steam_home_directory}"
  else
    HOME="${SOURCE_DATA_HOME}/${steam_home_directory}"
  fi
  export HOME
  export XDG_CACHE_HOME="${HOME}/.cache"
  export XDG_CONFIG_HOME="${HOME}/.config"
  export XDG_DATA_HOME="${HOME}/.local/share"
  export XDG_STATE_HOME="${HOME}/.local/state"

  STEAM_DIRECTORY="${XDG_DATA_HOME}/Steam"
  CLIENT_DIRECTORY="${STEAM_DIRECTORY}/steamrtarm64"
  COMPATIBILITY_DIRECTORY="${STEAM_DIRECTORY}/compatibilitytools.d/\
${COMPATIBILITY_TOOL_DIRECTORY}"
  PROTON_DIRECTORY_PATH="${STEAM_DIRECTORY}/steamapps/common/\
${PROTON_DIRECTORY}"
  RUNTIME_DIRECTORY_PATH="${STEAM_DIRECTORY}/steamapps/common/\
${RUNTIME_DIRECTORY}"
  readonly \
    CLIENT_DIRECTORY \
    COMPATIBILITY_DIRECTORY \
    PROTON_DIRECTORY_PATH \
    RUNTIME_DIRECTORY_PATH \
    SOURCE_CONFIG_HOME \
    SOURCE_DATA_HOME \
    SOURCE_HOME \
    STEAM_DIRECTORY
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

# Steam's PID belongs to the muvm guest and cannot be checked against the
# host's /proc. Hold a host-side lock in a supervising flock process instead.
run_with_steam_lock() {
  local -i status
  local lock_path="${STEAM_DIRECTORY}/.steam-asahi.lock"

  mkdir -p -- "${STEAM_DIRECTORY}"
  if "${FLOCK}" \
    --nonblock \
    --conflict-exit-code 73 \
    "${lock_path}" \
    "${ENV_BIN}" \
    HOME="${SOURCE_HOME}" \
    XDG_CONFIG_HOME="${SOURCE_CONFIG_HOME}" \
    XDG_DATA_HOME="${SOURCE_DATA_HOME}" \
    STEAM_ASAHI_LOCKED=1 \
    "${BASH}" "$0" "$@"; then
    status=0
  else
    status=$?
  fi

  if (( status == 73 )); then
    if [[ "${1:-}" == '--force-proton' ]]; then
      die 'Close Steam before changing a compatibility-tool mapping'
    fi
    die 'Steam Asahi is already running'
  fi
  exit "${status}"
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

# Keeps PulseAudio cookie authentication working without exposing any other
# host configuration to the isolated client.
sync_pulse_cookie() {
  local source_cookie="${SOURCE_CONFIG_HOME}/pulse/cookie"
  local target_cookie="${XDG_CONFIG_HOME:-${HOME}/.config}/pulse/cookie"

  if [[ ! -f "${source_cookie}" \
    && -f "${SOURCE_HOME}/.pulse-cookie" ]]; then
    source_cookie="${SOURCE_HOME}/.pulse-cookie"
  fi
  [[ -f "${source_cookie}" && "${source_cookie}" != "${target_cookie}" ]] \
    || return 0

  # Reinstall even when the content matches so a permissive target mode is
  # repaired to the authentication cookie's required private mode.
  mkdir -p -- "$(dirname -- "${target_cookie}")"
  install_managed_file "${source_cookie}" "${target_cookie}" 0600
}

# The ARM beta's login UI is unreliable. Copy the minimum state used by the
# proven development importer only after an explicit user request.
import_login_state() {
  local source_registry="${SOURCE_HOME}/.steam/registry.vdf"
  local source_steam="${SOURCE_DATA_HOME}/Steam"

  [[ "${source_steam}" != "${STEAM_DIRECTORY}" ]] || die \
    'the source and isolated Steam directories are identical'
  if [[ ! -f "${source_steam}/local.vdf" \
    || ! -f "${source_steam}/config/loginusers.vdf" \
    || ! -f "${source_steam}/config/config.vdf" ]]; then
    die "incomplete x86 Steam login under ${source_steam}"
  fi

  mkdir -p -- "${STEAM_DIRECTORY}/config" "${HOME}/.steam"
  install_managed_file \
    "${source_steam}/local.vdf" \
    "${STEAM_DIRECTORY}/local.vdf" \
    0600
  install_managed_file \
    "${source_steam}/config/loginusers.vdf" \
    "${STEAM_DIRECTORY}/config/loginusers.vdf" \
    0600
  install_managed_file \
    "${source_steam}/config/config.vdf" \
    "${STEAM_DIRECTORY}/config/config.vdf" \
    0600
  if [[ -f "${source_registry}" ]]; then
    install_managed_file \
      "${source_registry}" "${HOME}/.steam/registry.vdf" 0600
  fi
  printf 'Imported the x86 Steam login into isolated state at %s.\n' \
    "${HOME}"
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
  local -a launcher_arguments=("$@")
  local import_login=false
  local force_proton_app_id=

  (( EUID != 0 )) || die 'Do not run steam-asahi as root'
  initialize_steam_home

  if [[ "${1:-}" == '--import-login' ]]; then
    import_login=true
    shift
  fi
  if [[ "${1:-}" == '--guest' ]]; then
    [[ "${import_login}" == false ]] || die \
      '--import-login cannot be combined with --guest'
    shift
    (( $# > 0 )) || die 'usage: steam-asahi --guest command [arguments...]'
    run_guest "$@"
  fi

  printf 'Using isolated ARM64 Steam home: %s\n' "${HOME}"
  if [[ "${STEAM_ASAHI_LOCKED:-0}" != 1 ]]; then
    run_with_steam_lock "${launcher_arguments[@]}"
  fi

  if [[ "${1:-}" == '--force-proton' ]]; then
    shift
    (( $# > 0 )) || die 'usage: steam-asahi --force-proton APPID'
    force_proton_app_id=$1
    shift
    if [[ ! "${force_proton_app_id}" =~ ^[1-9][0-9]*$ ]]; then
      die 'APPID must be a positive decimal integer'
    fi
  fi

  warn_missing_audio_socket
  sync_pulse_cookie
  install_client_bootstrap
  configure_steam_state
  if [[ "${import_login}" == true ]]; then
    import_login_state
  fi
  install_proton_integration
  if [[ -n "${force_proton_app_id}" ]]; then
    [[ -x "${PROTON_DIRECTORY_PATH}/proton" \
      && -x "${RUNTIME_DIRECTORY_PATH}/_v2-entry-point" \
      && -x "${COMPATIBILITY_DIRECTORY}/steam-asahi-proton" ]] \
      || die \
        "${DISPLAY_NAME} and Steam Linux Runtime 4.0 - Arm64" \
        'must be installed'
    "${PROTON_CONFIGURATOR}" \
      "${STEAM_DIRECTORY}/config/config.vdf" \
      "${force_proton_app_id}" \
      "${PROTON_TOOL_NAME}"
    set -- "steam://run/${force_proton_app_id}" "$@"
  fi
  show_splash

  printf '%s\n' 'Launching native ARM64 Steam via muvm...'
  run_guest --steam "${CLIENT_DIRECTORY}/steam" -cef-force-occlusion "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
