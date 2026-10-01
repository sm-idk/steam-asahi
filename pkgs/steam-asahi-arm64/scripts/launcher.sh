#!/usr/bin/env bash
# shellcheck shell=bash
#
# Installs the managed ARM64 Steam state and launches it through muvm.
# Nix supplies Bash 5.3; `${ command; }` captures output without a subshell.

set -o errexit
set -o nounset
set -o pipefail

: "${COMMON_SCRIPT:=${BASH_SOURCE[0]%/*}/../../scripts/common.sh}"
# shellcheck source=/dev/null
source "${COMMON_SCRIPT}"
readonly COMMON_SCRIPT

readonly -a REQUIRED_CONFIGURATION_VARIABLES=(
  CLIENT_BOOTSTRAP
  CLIENT_UPDATE_CHANNEL
  COMPATIBILITY_TOOL_DIRECTORY
  COMPATIBILITY_TOOL_VDF
  DEFAULT_STEAM_HOME_DIR
  DISPLAY_NAME
  ENV_BIN
  FLOCK
  GUEST_LAUNCHER
  HOST_LIBRARIES
  INIT_SCRIPT
  LAUNCHER_COMMAND
  MUVM
  PROTON_DIRECTORY
  PROTON_CONFIGURATOR
  PROTON_RUNNER
  PROTON_TOOL_NAME
  PROTON_WRAPPER
  RUNTIME_APP_ID
  RUNTIME_DIRECTORY
  TOOL_MANIFEST
  YAD
)
require_configuration_variables "${REQUIRED_CONFIGURATION_VARIABLES[@]}"
require_declared_configuration_variables CUSTOM_STEAM_HOME_DIR
# These values implement interfaces provided by the sourced common module.
: "${ENV_BIN}" "${YAD}"

readonly -a CPU_ARGS
readonly -a MEMORY_ARGS
readonly -a NETWORK_ARGS
readonly -a VRAM_ARGS

readonly -a MUVM_BASE_ARGS=(
  --gpu-mode=drm
  "${CPU_ARGS[@]}"
  "${MEMORY_ARGS[@]}"
  "${VRAM_ARGS[@]}"
  "${NETWORK_ARGS[@]}"
  --execute-pre "${INIT_SCRIPT}"
)
# muvm proxies a forwarded command's stdio only when asked to be interactive,
# and that proxy registers stdin with epoll, which rejects the /dev/null an
# application launcher provides. The flag is ignored when muvm boots a
# microVM, so only a diagnostic a person runs from a terminal asks for it.
# shellcheck disable=SC2034
readonly -a MUVM_DETACHED_ARGS=()
# shellcheck disable=SC2034
readonly -a MUVM_INTERACTIVE_ARGS=(--interactive)
# The prefix the client gives the artwork of the shortcuts it generates.
readonly CLIENT_ICON_PREFIX=steam_icon_
readonly EXECUTABLE_FILE_MODE=0755
readonly EXPORTED_ENTRY_PREFIX=steam-asahi-
readonly LEGACY_COMPATIBILITY_FILE=steam-asahi-arm64.vdf
# EX_CANTCREAT is outside the normal command-exit range and reserved here for
# flock's synthetic lock-contention status.
readonly LOCK_CONFLICT_EXIT_STATUS=73
readonly MAX_PROTON_LOG_SIZE_BYTES=$(( 1024 * 1024 ))
readonly MUVM_RUNTIME_LOCK_FILE=muvm.lock
readonly PRIVATE_FILE_MODE=0600
readonly READ_ONLY_FILE_MODE=0644
readonly RUNTIME_DISPLAY_NAME='Steam Linux Runtime 4.0 - Arm64'
readonly SHORTCUT_EXPORT_INTERVAL_SECONDS=5
readonly SPLASH_HOLD_SECONDS=5

# Resolves the isolated state only when the executable enters main. Keeping
# this out of global scope avoids rewriting a sourcing shell's HOME/XDG paths.
initialize_steam_home() {
  local steam_home_directory
  local variable_name
  local -Ar xdg_home_suffixes=(
    [XDG_CACHE_HOME]=.cache
    [XDG_CONFIG_HOME]=.config
    [XDG_DATA_HOME]=.local/share
    [XDG_STATE_HOME]=.local/state
  )

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
  for variable_name in "${!xdg_home_suffixes[@]}"; do
    printf -v "${variable_name}" '%s' \
      "${HOME}/${xdg_home_suffixes[${variable_name}]}"
    export "${variable_name?}"
  done

  STEAM_DIRECTORY="${XDG_DATA_HOME}/Steam"
  CLIENT_DIRECTORY="${STEAM_DIRECTORY}/${ARM64_CLIENT_DIRECTORY_NAME}"
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

# Steam's PID belongs to the muvm guest and cannot be checked against the
# host's /proc. Keep a host-side lock across the launcher's exec chain instead.
run_with_steam_lock() {
  local -i status
  local lock_path="${STEAM_DIRECTORY}/.steam-asahi.lock"

  mkdir -p -- "${STEAM_DIRECTORY}"
  if "${FLOCK}" \
    --nonblock \
    --no-fork \
    --conflict-exit-code "${LOCK_CONFLICT_EXIT_STATUS}" \
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

  if (( status == LOCK_CONFLICT_EXIT_STATUS )); then
    if [[ "${1:-}" == '--force-proton' ]]; then
      die 'Close Steam before changing a compatibility-tool mapping'
    fi
    forward_client_urls "$@"
    die 'Steam Asahi is already running'
  fi
  exit "${status}"
}

# The first argument names the array of muvm stdio options to apply.
run_guest() {
  local stdio_options_name=$1
  local -n stdio_options="${stdio_options_name}"

  shift
  run_in_clean_environment \
    "${MUVM}" \
    "${MUVM_BASE_ARGS[@]}" \
    "${stdio_options[@]}" \
    -e "PRESSURE_VESSEL_FILESYSTEMS_RO=${PRESSURE_VESSEL_FILESYSTEMS_RO}" \
    -e "STEAM_ASAHI_GUEST_HOME=${HOME}" \
    -e "STEAM_ASAHI_GUEST_UID=${EUID}" \
    -- \
    "${GUEST_LAUNCHER}" "$@"
}

# muvm refuses to boot a second microVM while another instance holds its
# runtime lock, and launches the requested command inside the running guest
# instead. Probing that same lock tells the launcher which case it is in.
muvm_instance_running() {
  local lock_path
  local -i status

  printf -v lock_path '%s/%s' \
    "${XDG_RUNTIME_DIR:-/run/user/${EUID}}" \
    "${MUVM_RUNTIME_LOCK_FILE}"
  [[ -f "${lock_path}" ]] || return 1
  if "${FLOCK}" \
    --nonblock \
    --no-fork \
    --conflict-exit-code "${LOCK_CONFLICT_EXIT_STATUS}" \
    "${lock_path}" \
    true; then
    status=0
  else
    status=$?
  fi
  (( status == LOCK_CONFLICT_EXIT_STATUS ))
}

# Shortcuts generated by the client run `steam steam://rungameid/...`, which
# has to reach the client that already owns the microVM. Re-enter that guest
# and let Valve's binary hand the URL to its running instance over the pipe it
# keeps in the isolated home; it exits as soon as the handover completes.
forward_client_urls() {
  local url

  (( $# > 0 )) || return 0
  for url in "$@"; do
    [[ "${url}" == steam://* ]] || return 0
  done
  muvm_instance_running || return 0

  printf 'Handing %s to the running ARM64 Steam client...\n' "$*"
  run_guest MUVM_DETACHED_ARGS "${CLIENT_DIRECTORY}/steam" "$@"
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
  mkdir -p -- "${target_cookie%/*}"
  install_managed_file \
    "${source_cookie}" "${target_cookie}" "${PRIVATE_FILE_MODE}"
}

# The ARM beta's login UI is unreliable. Copy the minimum state used by the
# proven development importer only after an explicit user request.
import_login_state() {
  local relative_path
  local source_registry="${SOURCE_HOME}/.steam/registry.vdf"
  local source_steam="${SOURCE_DATA_HOME}/Steam"
  local -ar required_paths=(
    local.vdf
    config/loginusers.vdf
    config/config.vdf
  )

  [[ "${source_steam}" != "${STEAM_DIRECTORY}" ]] || die \
    'the source and isolated Steam directories are identical'
  for relative_path in "${required_paths[@]}"; do
    [[ -f "${source_steam}/${relative_path}" ]] \
      || die "incomplete x86 Steam login under ${source_steam}"
  done

  mkdir -p -- "${STEAM_DIRECTORY}/config" "${HOME}/.steam"
  for relative_path in "${required_paths[@]}"; do
    install_managed_file \
      "${source_steam}/${relative_path}" \
      "${STEAM_DIRECTORY}/${relative_path}" \
      "${PRIVATE_FILE_MODE}"
  done
  if [[ -f "${source_registry}" ]]; then
    install_managed_file \
      "${source_registry}" \
      "${HOME}/.steam/registry.vdf" \
      "${PRIVATE_FILE_MODE}"
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
  cp --archive --no-target-directory -- \
    "${CLIENT_BOOTSTRAP}" \
    "${CLIENT_DIRECTORY}"
  chmod -RP u+rwX -- "${CLIENT_DIRECTORY}"
}

configure_steam_state() {
  local beta_file="${STEAM_DIRECTORY}/package/beta"
  local destination
  local -Ar steam_links=(
    ["${HOME}/.steam/root"]="${STEAM_DIRECTORY}"
    ["${HOME}/.steam/sdkarm64"]="${STEAM_DIRECTORY}/linuxarm64"
    ["${HOME}/.steam/steam"]="${STEAM_DIRECTORY}"
  )

  mkdir -p -- "${beta_file%/*}" "${HOME}/.steam"
  if [[ ! -f "${beta_file}" \
    || "$(<"${beta_file}")" != "${CLIENT_UPDATE_CHANNEL}" ]]; then
    write_managed_value "${beta_file}" "${CLIENT_UPDATE_CHANNEL}"
  fi

  for destination in "${!steam_links[@]}"; do
    if [[ ! -e "${destination}" && ! -L "${destination}" ]]; then
      ln --symbolic --no-target-directory -- \
        "${steam_links[${destination}]}" \
        "${destination}"
    fi
  done
}

proton_payloads_installed() {
  [[ -x "${PROTON_DIRECTORY_PATH}/proton" \
    && -x "${RUNTIME_DIRECTORY_PATH}/_v2-entry-point" ]]
}

proton_integration_ready() {
  proton_payloads_installed \
    && [[ -x "${COMPATIBILITY_DIRECTORY}/steam-asahi-proton" ]]
}

# Materializes the small managed compatibility-tool wrapper only after both
# Valve-managed payloads are installed, then bounds its diagnostic log.
install_proton_integration() {
  local file_name
  local link_name
  local log_path="${COMPATIBILITY_DIRECTORY}/steam-asahi-proton.log"
  local log_size
  local -Ar managed_files=(
    [compatibilitytool.vdf]="${COMPATIBILITY_TOOL_VDF}"
    [run-proton]="${PROTON_RUNNER}"
    [steam-asahi-proton]="${PROTON_WRAPPER}"
    [toolmanifest.vdf]="${TOOL_MANIFEST}"
  )
  local -Ar managed_file_modes=(
    [compatibilitytool.vdf]="${READ_ONLY_FILE_MODE}"
    [run-proton]="${EXECUTABLE_FILE_MODE}"
    [steam-asahi-proton]="${EXECUTABLE_FILE_MODE}"
    [toolmanifest.vdf]="${READ_ONLY_FILE_MODE}"
  )
  local -Ar managed_links=(
    [host-libs]="${HOST_LIBRARIES}"
    [proton]="${PROTON_DIRECTORY_PATH}"
    [runtime]="${RUNTIME_DIRECTORY_PATH}"
  )

  if proton_payloads_installed; then
    mkdir -p -- "${COMPATIBILITY_DIRECTORY}"
    for file_name in "${!managed_files[@]}"; do
      install_managed_file \
        "${managed_files[${file_name}]}" \
        "${COMPATIBILITY_DIRECTORY}/${file_name}" \
        "${managed_file_modes[${file_name}]}"
    done
    for link_name in "${!managed_links[@]}"; do
      ln --symbolic --force --no-target-directory -- \
        "${managed_links[${link_name}]}" \
        "${COMPATIBILITY_DIRECTORY}/${link_name}"
    done
    rm -f -- \
      "${STEAM_DIRECTORY}/compatibilitytools.d/\
${LEGACY_COMPATIBILITY_FILE}"

    if log_size=$(stat -c %s -- "${log_path}" 2>/dev/null) \
      && (( log_size > MAX_PROTON_LOG_SIZE_BYTES )); then
      # Diagnostic-log rotation must not prevent Steam from launching if two
      # launchers race or the log disappears between stat(2) and rename(2).
      mv \
        --force \
        --no-copy \
        --no-target-directory \
        -- \
        "${log_path}" \
        "${log_path}.old" \
        2>/dev/null || true
    fi
  elif [[ -x "${PROTON_DIRECTORY_PATH}/proton" ]]; then
    printf '%s is installed, but %s (AppID %s) is missing.\n' \
      "${DISPLAY_NAME}" \
      "${RUNTIME_DISPLAY_NAME}" \
      "${RUNTIME_APP_ID}" >&2
  fi
}

# A mirrored entry is refreshed when it is missing, older than the client's own
# entry, or no longer carries that entry's mode. Without the last case a
# mirror written with the wrong mode would never be repaired, because it is
# always the newer file.
entry_needs_export() {
  local source_path=$1
  local target_path=$2

  [[ -f "${target_path}" ]] || return 0
  [[ ! "${source_path}" -nt "${target_path}" ]] || return 0
  [[ "${ stat -c %a -- "${source_path}"; }" \
    != "${ stat -c %a -- "${target_path}"; }" ]]
}

exported_entry_has_source() {
  local entry_name=$1
  local source_directory

  shift
  for source_directory in "$@"; do
    [[ ! -f "${source_directory}/${entry_name}" ]] || return 0
  done
  return 1
}

# Both shortcut locations the client writes to live below the isolated home,
# where the host's application launcher never looks. Mirror them into the real
# data home and drop the exports whose originals are gone.
export_desktop_entries() {
  local -r GLOBSORT=nosort
  local entry_name
  local source_directory
  local -ar source_directories=(
    "${HOME}/Desktop"
    "${XDG_DATA_HOME}/applications"
  )
  local source_path
  local -a source_paths
  local target_directory="${SOURCE_DATA_HOME}/applications"
  local target_path
  local -a target_paths

  mkdir -p -- "${target_directory}"
  for source_directory in "${source_directories[@]}"; do
    source_paths=("${source_directory}"/*.desktop)
    for source_path in "${source_paths[@]}"; do
      entry_name="${source_path##*/}"
      target_path="${target_directory}/${EXPORTED_ENTRY_PREFIX}${entry_name}"
      entry_needs_export "${source_path}" "${target_path}" || continue
      install_managed_desktop_entry \
        "${source_path}" "${target_path}" "${LAUNCHER_COMMAND}"
    done
  done

  target_paths=("${target_directory}/${EXPORTED_ENTRY_PREFIX}"*.desktop)
  for target_path in "${target_paths[@]}"; do
    desktop_entry_is_managed "${target_path}" || continue
    entry_name="${target_path##*/}"
    entry_name="${entry_name#"${EXPORTED_ENTRY_PREFIX}"}"
    exported_entry_has_source "${entry_name}" "${source_directories[@]}" \
      || rm -f -- "${target_path}"
  done
}

# Exported entries reference per-game icons by name, so the artwork has to
# follow them out of the isolated home into the same theme directories. Nothing
# is removed here: artwork that no entry names is already invisible, and the
# x86 backend installs identically named icons into this very directory.
export_shortcut_icons() {
  local -r GLOBSORT=nosort
  local relative_path
  local source_directory="${XDG_DATA_HOME}/icons"
  local source_path
  local -a source_paths
  local target_directory="${SOURCE_DATA_HOME}/icons"
  local target_path

  source_paths=("${source_directory}"/*/*/apps/"${CLIENT_ICON_PREFIX}"*)
  for source_path in "${source_paths[@]}"; do
    relative_path="${source_path#"${source_directory}/"}"
    target_path="${target_directory}/${relative_path}"
    [[ ! -f "${target_path}" || "${source_path}" -nt "${target_path}" ]] \
      || continue
    mkdir -p -- "${target_path%/*}"
    install_managed_file \
      "${source_path}" "${target_path}" "${READ_ONLY_FILE_MODE}"
  done
}

export_client_shortcuts() {
  # An isolated home pointed back at the caller's own data home would export
  # each entry onto itself.
  [[ "${SOURCE_DATA_HOME}" != "${XDG_DATA_HOME}" ]] || return 0
  export_shortcut_icons
  export_desktop_entries
}

# The launcher execs into muvm, so shortcuts added during a session can only be
# observed by a watcher that outlives that exec. It polls because the isolated
# home reaches the client through virtiofs, where inotify events raised inside
# the microVM never surface on the host. The unlocked pass it watches lives for
# exactly as long as the client does.
start_shortcut_export() {
  local launcher_pid=$$

  export_client_shortcuts
  (
    while kill -0 "${launcher_pid}" 2>/dev/null; do
      sleep "${SHORTCUT_EXPORT_INTERVAL_SECONDS}"
      export_client_shortcuts || true
    done
    export_client_shortcuts || true
  ) >/dev/null 2>&1 &
}

show_splash() {
  local cef_log="${STEAM_DIRECTORY}/logs/cef_log.txt"

  show_startup_splash \
    "${cef_log}" \
    "${SPLASH_HOLD_SECONDS}" \
    'Starting native ARM64 Steam (4K-page microVM)...'
}

main() {
  local -a launcher_arguments=("$@")
  local -i import_login=0
  local force_proton_app_id=

  (( EUID != 0 )) || die 'Do not run steam-asahi as root'
  initialize_steam_home

  if [[ "${1:-}" == '--import-login' ]]; then
    import_login=1
    shift
  fi
  if [[ "${1:-}" == '--guest' ]]; then
    (( import_login == 0 )) || die \
      '--import-login cannot be combined with --guest'
    shift
    (( $# > 0 )) || die 'usage: steam-asahi --guest command [arguments...]'
    run_guest MUVM_INTERACTIVE_ARGS "$@"
  fi

  printf 'Using isolated ARM64 Steam home: %s\n' "${HOME}"
  if [[ "${STEAM_ASAHI_LOCKED:-0}" != 1 ]]; then
    # `flock --no-fork` passes its lock descriptor to the pass it runs and to
    # every process that pass starts. The watcher outlives the client, so it
    # has to be started here, where no descriptor can be inherited from it.
    start_shortcut_export
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
  if (( import_login )); then
    import_login_state
  fi
  install_proton_integration
  if [[ -n "${force_proton_app_id}" ]]; then
    proton_integration_ready \
      || die "${DISPLAY_NAME} and ${RUNTIME_DISPLAY_NAME} must be installed"
    "${PROTON_CONFIGURATOR}" \
      "${STEAM_DIRECTORY}/config/config.vdf" \
      "${force_proton_app_id}" \
      "${PROTON_TOOL_NAME}"
    set -- "steam://run/${force_proton_app_id}" "$@"
  fi
  show_splash

  printf '%s\n' 'Launching native ARM64 Steam via muvm...'
  run_guest \
    MUVM_DETACHED_ARGS \
    --steam \
    "${CLIENT_DIRECTORY}/steam" \
    "${STEAM_CLIENT_ARGS[@]}" \
    "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  shopt -s array_expand_once inherit_errexit nullglob
  main "$@"
fi
