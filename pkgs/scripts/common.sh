# shellcheck shell=bash
# shellcheck disable=SC2034
#
# Shared runtime policy for the Steam Asahi launchers and guest setup scripts.

if [[ -v STEAM_ASAHI_COMMON_LOADED ]]; then
  return 0
fi
readonly STEAM_ASAHI_COMMON_LOADED=1

declare_readonly_array_default() {
  local variable_name=$1

  shift
  if ! declare -p "${variable_name}" &>/dev/null; then
    declare -g -a "${variable_name}"
    local -n values="${variable_name}"

    values=("$@")
  fi
  readonly "${variable_name}"
}

readonly C_LOCALE=C.UTF-8
readonly ARM64_CLIENT_DIRECTORY_NAME=steamrtarm64
readonly ETC_STUB_FILE_MODE=0644
readonly FHS_ROOT=/run/fhs
readonly LOCALE_ARCHIVE_PATH=/run/current-system/sw/lib/locale/locale-archive
readonly OPENGL_DRIVER_ROOT=/run/opengl-driver
readonly OPENGL_VULKAN_SHARE="${OPENGL_DRIVER_ROOT}/share/vulkan"
readonly PCI_DEVICES_DIRECTORY=/sys/bus/pci/devices
readonly PRESSURE_VESSEL_SHARE=\
"${FHS_ROOT}/usr/lib/pressure-vessel/overrides/share"
readonly SPLASH_BORDER_WIDTH=16
readonly SPLASH_TIMEOUT_SECONDS=180
readonly TZDATA_DIRECTORY=/usr/share/zoneinfo
readonly VULKAN_OVERRIDES="${PRESSURE_VESSEL_SHARE}/vulkan"
readonly VULKAN_SHARE="${FHS_ROOT}/usr/share/vulkan"
readonly WRAPPERS_BIN_DIRECTORY=/run/wrappers/bin

declare_readonly_array_default HOST_LOCALE_VARIABLES \
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

declare_readonly_array_default CLEAN_ENVIRONMENT_VARIABLES \
  BASH_ENV \
  ENV \
  "${HOST_LOCALE_VARIABLES[@]}"

declare_readonly_array_default GUEST_PATH_ENTRIES \
  /usr/local/bin \
  /usr/bin \
  /bin

declare_readonly_array_default GUEST_DATA_DIRECTORIES \
  "${OPENGL_DRIVER_ROOT}/share" \
  /run/current-system/sw/share \
  /usr/local/share \
  /usr/share

declare_readonly_array_default ARM64_RUNTIME_TOOL_RELATIVE_DIRECTORIES \
  SteamLinuxRuntime_4-arm64/pressure-vessel/bin \
  SteamLinuxRuntime_soldier/pressure-vessel-arm64/bin

readonly -A COMMON_DRIVER_ENVIRONMENT=(
  [LIBGL_DRIVERS_PATH]="${OPENGL_DRIVER_ROOT}/lib/dri"
  [LIBVA_DRIVERS_PATH]="${OPENGL_DRIVER_ROOT}/lib/dri"
  [VDPAU_DRIVER_PATH]="${OPENGL_DRIVER_ROOT}/lib/vdpau"
  [__EGL_VENDOR_LIBRARY_DIRS]=\
"${OPENGL_DRIVER_ROOT}/share/glvnd/egl_vendor.d"
)

readonly -A ARM64_DRIVER_ENVIRONMENT=(
  [MESA_LOADER_DRIVER_OVERRIDE]=asahi
  [VK_DRIVER_FILES]=\
"${OPENGL_VULKAN_SHARE}/icd.d/asahi_icd.aarch64.json"
)

declare_readonly_array_default ETC_STUB_DIRS \
  ld.so.conf.d \
  alternatives \
  xdg \
  pulse

declare_readonly_array_default ETC_STUB_FILES \
  ld.so.cache \
  ld.so.conf \
  timezone

declare_readonly_array_default ETC_SYMLINKS_TO_MATERIALIZE \
  host.conf \
  hosts \
  localtime \
  os-release \
  resolv.conf \
  nsswitch.conf \
  group \
  passwd \
  machine-id

declare_readonly_array_default VULKAN_SUBDIRECTORIES \
  icd.d \
  explicit_layer.d \
  implicit_layer.d

declare_readonly_array_default PRESSURE_VESSEL_READ_ONLY_PATHS \
  /nix \
  "${OPENGL_DRIVER_ROOT}"
# Guest mounts are self-contained. Ignore host fstab policy, bypass helpers,
# and refuse to stack an identical mount when an init script is retried.
declare_readonly_array_default MOUNT_BASE_ARGS \
  --internal-only \
  --onlyonce \
  --options-source=disable
declare_readonly_array_default STEAM_CLIENT_ARGS \
  -cef-force-occlusion

join_colon_values() {
  local result_name=$1
  local IFS=:

  shift
  printf -v "${result_name}" '%s' "$*"
}

join_colon_values \
  PRESSURE_VESSEL_FILESYSTEMS_RO \
  "${PRESSURE_VESSEL_READ_ONLY_PATHS[@]}"
readonly PRESSURE_VESSEL_FILESYSTEMS_RO

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_configuration_variables() {
  local variable_name

  for variable_name in "$@"; do
    [[ -n "${!variable_name-}" ]] \
      || die "internal configuration ${variable_name} was not injected"
    readonly "${variable_name}"
  done
}

require_declared_configuration_variables() {
  local variable_name

  for variable_name in "$@"; do
    [[ -v "${variable_name}" ]] \
      || die "internal configuration ${variable_name} was not injected"
    readonly "${variable_name}"
  done
}

export_default_environment() {
  local defaults_name=$1
  local variable_name
  local -n defaults="${defaults_name}"

  for variable_name in "${!defaults[@]}"; do
    if [[ -z "${!variable_name-}" ]]; then
      printf -v "${variable_name}" '%s' "${defaults[${variable_name}]}"
    fi
    export "${variable_name?}"
  done
}

prepend_colon_path() {
  local variable_name=$1
  local existing_value=${!variable_name-}
  local joined_value
  local IFS=:

  shift
  joined_value="$*${existing_value:+:${existing_value}}"
  printf -v "${variable_name}" '%s' "${joined_value}"
  export "${variable_name?}"
}

run_in_clean_environment() {
  local variable_name
  local -a arguments=()

  for variable_name in "${CLEAN_ENVIRONMENT_VARIABLES[@]}"; do
    arguments+=(-u "${variable_name}")
  done
  exec "${ENV_BIN}" \
    "${arguments[@]}" \
    LANG="${C_LOCALE}" \
    LC_ALL="${C_LOCALE}" \
    "$@"
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

run_lspci_if_devices_exist() {
  local -r GLOBSORT=nosort
  local -a device_paths

  if [[ -d "${PCI_DEVICES_DIRECTORY}" ]]; then
    device_paths=("${PCI_DEVICES_DIRECTORY}"/*)
    (( ${#device_paths[@]} == 0 )) || exec lspci "$@"
  fi
}

# Displays a bounded startup dialog without delaying or owning the launched
# process. The background watcher always removes its temporary marker.
show_startup_splash() {
  local cef_log=$1
  local hold_seconds=$2
  local splash_text=$3
  local -i deadline=$(( BASH_MONOSECONDS + SPLASH_TIMEOUT_SECONDS ))
  local launcher_pid=$$
  local marker
  local splash_pid
  local -i ui_started=0

  [[ "${STEAM_ASAHI_NO_SPLASH:-0}" == 1 || -t 0 || -t 1 ]] && return

  marker=${ mktemp; }
  "${YAD}" \
    --no-buttons \
    --center \
    --borders="${SPLASH_BORDER_WIDTH}" \
    --title=Steam \
    --window-icon=steam \
    --skip-taskbar \
    --timeout="${SPLASH_TIMEOUT_SECONDS}" \
    --text="${splash_text}" &
  splash_pid=$!

  (
    trap 'kill "${splash_pid}" 2>/dev/null || true; rm -f -- "${marker}"' EXIT

    while (( BASH_MONOSECONDS < deadline )); do
      kill -0 "${launcher_pid}" 2>/dev/null || break
      if [[ -f "${cef_log}" && "${cef_log}" -nt "${marker}" ]]; then
        ui_started=1
        break
      fi
      sleep 1
    done

    (( ui_started == 0 )) || sleep "${hold_seconds}"
  ) &
}

# Keeping temporary files beside their destinations makes the final no-copy
# rename atomic and prevents a silent copy-and-delete fallback.
create_managed_temporary_path() {
  local result_name=$1
  local destination=$2
  local destination_directory=${destination%/*}
  local destination_name=${destination##*/}
  local generated_path

  [[ "${destination_directory}" != "${destination}" ]] \
    || destination_directory=.
  generated_path=${ mktemp \
    --tmpdir="${destination_directory}" \
    ".${destination_name}.XXXXXX"; }
  printf -v "${result_name}" '%s' "${generated_path}"
}

install_managed_file() {
  local temporary_path
  local destination=$2
  local mode=$3
  local source_path=$1

  create_managed_temporary_path temporary_path "${destination}"
  if ! install \
    --mode="${mode}" \
    --no-target-directory \
    -- \
    "${source_path}" \
    "${temporary_path}"; then
    rm -f -- "${temporary_path}"
    return 1
  fi
  if ! mv \
    --force \
    --no-copy \
    --no-target-directory \
    -- \
    "${temporary_path}" \
    "${destination}"; then
    rm -f -- "${temporary_path}"
    return 1
  fi
}

write_managed_value() {
  local destination=$1
  local temporary_path
  local value=$2

  create_managed_temporary_path temporary_path "${destination}"
  if ! printf '%s\n' "${value}" >"${temporary_path}"; then
    rm -f -- "${temporary_path}"
    return 1
  fi
  if ! mv \
    --force \
    --no-copy \
    --no-target-directory \
    -- \
    "${temporary_path}" \
    "${destination}"; then
    rm -f -- "${temporary_path}"
    return 1
  fi
}

materialize_etc_symlink() {
  local file_name=$1
  local path="${FHS_ROOT}/etc/${file_name}"
  local target

  [[ -L "${path}" ]] || return 0
  target=$(readlink -f -- "${path}" 2>/dev/null) || return 0
  rm -f -- "${path}"

  if [[ -f "${target}" ]]; then
    cp --no-target-directory -- "${target}" "${path}"
  elif [[ -d "${target}" ]]; then
    mkdir -p -- "${path}"
    cp --archive --one-file-system -- "${target}/." "${path}/"
  fi
}

populate_etc_overlay() {
  local relative_path

  mkdir -p -- "${FHS_ROOT}/etc"
  cp --archive --one-file-system -- /etc/. "${FHS_ROOT}/etc/" \
    2>/dev/null || true
  for relative_path in "${ETC_SYMLINKS_TO_MATERIALIZE[@]}"; do
    materialize_etc_symlink "${relative_path}"
  done
  for relative_path in "${ETC_STUB_DIRS[@]}"; do
    mkdir -p -- "${FHS_ROOT}/etc/${relative_path}"
  done
  for relative_path in "${ETC_STUB_FILES[@]}"; do
    rm -f -- "${FHS_ROOT}/etc/${relative_path}"
    install \
      --mode="${ETC_STUB_FILE_MODE}" \
      --no-target-directory \
      -- \
      /dev/null \
      "${FHS_ROOT}/etc/${relative_path}"
  done
}

# Mirrors graphics manifests into the native loader and Pressure Vessel paths.
# Additional arguments are copied into the implicit-layer directory.
install_vulkan_metadata() {
  local extra_manifest
  local -a manifest_paths
  local source_directory
  local subdirectory

  mkdir -p -- "${VULKAN_SHARE}" "${VULKAN_OVERRIDES}"
  for subdirectory in "${VULKAN_SUBDIRECTORIES[@]}"; do
    source_directory="${OPENGL_VULKAN_SHARE}/${subdirectory}"
    [[ -e "${source_directory}" ]] || continue
    rm --force --recursive --one-file-system --preserve-root=all -- \
      "${VULKAN_SHARE:?}/${subdirectory}"
    ln --symbolic --no-target-directory -- \
      "${source_directory}" \
      "${VULKAN_SHARE}/${subdirectory}"
    mkdir -p -- "${VULKAN_OVERRIDES}/${subdirectory}"
    manifest_paths=("${source_directory}"/*.json)
    (( ${#manifest_paths[@]} == 0 )) || ln \
      --symbolic \
      --force \
      --target-directory="${VULKAN_OVERRIDES}/${subdirectory}" \
      -- \
      "${manifest_paths[@]}"
  done

  (( $# == 0 )) && return
  mkdir -p -- "${VULKAN_OVERRIDES}/implicit_layer.d"
  for extra_manifest in "$@"; do
    [[ -f "${extra_manifest}" ]] || continue
    cp \
      --force \
      --remove-destination \
      --target-directory="${VULKAN_OVERRIDES}/implicit_layer.d" \
      -- \
      "${extra_manifest}" \
      2>/dev/null || true
  done
}

create_fhs_directories() {
  local relative_path

  for relative_path in "$@"; do
    mkdir -p -- "${FHS_ROOT}/${relative_path}"
  done
}

copy_host_fhs_directories() {
  local relative_path

  for relative_path in "$@"; do
    cp --archive --one-file-system -- \
      "/${relative_path}/." \
      "${FHS_ROOT}/${relative_path}/" \
      2>/dev/null || true
  done
}

bind_fhs_directories() {
  local relative_path

  for relative_path in "$@"; do
    mount \
      "${MOUNT_BASE_ARGS[@]}" \
      --bind \
      "${FHS_ROOT}/${relative_path}" \
      "/${relative_path}"
  done
}

unset -f \
  declare_readonly_array_default
