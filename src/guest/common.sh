# shellcheck shell=bash
# shellcheck disable=SC2034
#
# Shared runtime policy for the Steam Asahi guest setup scripts

# FEX uses the rootfs's Bash, independently of the version provided by Nix
if ((BASH_VERSINFO[0] < 5)) \
  || ((BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 3)); then
  printf 'ERROR: Steam Asahi requires Bash >= 5.3; found %s\n' \
    "${BASH_VERSION}" >&2
  exit 1
fi

if [[ -v STEAM_ASAHI_COMMON_LOADED ]]; then
  return 0
fi
readonly STEAM_ASAHI_COMMON_LOADED=1

# Declares an immutable array, preserving an explicitly supplied array
# Arguments: variable name, default elements
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
readonly GUEST_LOCALE_ARCHIVE_PATH=/usr/lib/locale/locale-archive
readonly LOCALE_ARCHIVE_PATH=/run/current-system/sw/lib/locale/locale-archive
readonly OPENGL_DRIVER_ROOT=/run/opengl-driver
readonly OPENGL_VULKAN_SHARE="${OPENGL_DRIVER_ROOT}/share/vulkan"
readonly EGL_VENDOR_DIRECTORY="${OPENGL_DRIVER_ROOT}/share/glvnd/egl_vendor.d"
readonly ARM64_VULKAN_ICD="${OPENGL_VULKAN_SHARE}/icd.d/asahi_icd.aarch64.json"
readonly PCI_DEVICES_DIRECTORY=/sys/bus/pci/devices
readonly MUVM_HOST_DIRECTORY=/run/muvm-host
readonly PRESSURE_VESSEL_DIRECTORY="${FHS_ROOT}/usr/lib/pressure-vessel"
readonly PRESSURE_VESSEL_SHARE="${PRESSURE_VESSEL_DIRECTORY}/overrides/share"
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
  [__EGL_VENDOR_LIBRARY_DIRS]="${EGL_VENDOR_DIRECTORY}"
)

readonly -A ARM64_DRIVER_ENVIRONMENT=(
  [MESA_LOADER_DRIVER_OVERRIDE]=asahi
  [VK_DRIVER_FILES]="${ARM64_VULKAN_ICD}"
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

# Guest mounts are self-contained. Ignore host fstab policy, bypass helpers,
# and refuse to stack an identical mount when an init script is retried
declare_readonly_array_default MOUNT_BASE_ARGS \
  --internal-only \
  --onlyonce \
  --options-source=disable

# Writes an error to stderr and exits with status 1
# Arguments: words of the error message
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# Requires nonempty configuration values and freezes them
# Arguments: names of variables injected by Nix
require_configuration_variables() {
  local variable_name

  for variable_name in "$@"; do
    [[ -n "${!variable_name-}" ]] \
      || die "internal configuration ${variable_name} was not injected"
    readonly "${variable_name}"
  done
}

# Requires muvm's host filesystem mount before any guest mount changes
# Globals: MUVM_HOST_DIRECTORY; requires util-linux mountpoint
require_muvm_guest() {
  mountpoint --quiet -- "${MUVM_HOST_DIRECTORY}" \
    || die 'guest initialization requires the muvm host filesystem mount'
}

# Exports an associative map of defaults, preserving nonempty overrides
# Arguments: associative array name
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

# Clears inherited locale categories and exports the guest's UTF-8 locale
# Globals: HOST_LOCALE_VARIABLES, C_LOCALE; writes LANG and LC_ALL
configure_guest_locale() {
  unset -v "${HOST_LOCALE_VARIABLES[@]}"
  export LC_ALL="${C_LOCALE}"
  export LANG="${C_LOCALE}"
}

# Exports shared graphics, audio, and data paths for the guest client
# Arguments: numeric host user ID, optional additional guest PATH entries
# Globals: guest path/data arrays and COMMON_DRIVER_ENVIRONMENT
configure_guest_environment() {
  local guest_uid=$1

  shift
  [[ "${guest_uid}" =~ ^[0-9]+$ ]] || die 'guest UID must be numeric'
  prepend_colon_path PATH "${GUEST_PATH_ENTRIES[@]}" "$@"
  export PULSE_SERVER="unix:/run/user/${guest_uid}/pulse/native"
  export SDL_AUDIODRIVER=pulseaudio
  prepend_colon_path XDG_DATA_DIRS "${GUEST_DATA_DIRECTORIES[@]}"
  export_default_environment COMMON_DRIVER_ENVIRONMENT
  configure_guest_locale
  # Pressure Vessel imports /usr/lib/locale but does not preserve the host's
  # /run/current-system path inside the nested game container
  export LOCALE_ARCHIVE="${GUEST_LOCALE_ARCHIVE_PATH}"
  export TZDIR="${TZDATA_DIRECTORY}"
  unset -v GIO_EXTRA_MODULES
}

# Prepends entries to an exported colon-separated path without empty entries
# Arguments: variable name, nonempty entries to prepend
prepend_colon_path() {
  local variable_name=$1
  local existing_value=${!variable_name-}
  local entry
  local joined_value=
  local -a existing_entries=()

  shift
  while [[ "${existing_value}" == *:* ]]; do
    existing_entries+=("${existing_value%%:*}")
    existing_value=${existing_value#*:}
  done
  existing_entries+=("${existing_value}")
  for entry in "$@" "${existing_entries[@]}"; do
    [[ -n "${entry}" ]] || continue
    joined_value+="${joined_value:+:}${entry}"
  done
  printf -v "${variable_name}" '%s' "${joined_value}"
  export "${variable_name?}"
}

# Runs lspci with the original arguments only when PCI devices exist
# Globals: PCI_DEVICES_DIRECTORY; requires nullglob
run_lspci_if_devices_exist() {
  local -r GLOBSORT=nosort
  local -a device_paths

  if [[ -d "${PCI_DEVICES_DIRECTORY}" ]]; then
    device_paths=("${PCI_DEVICES_DIRECTORY}"/*)
    ((${#device_paths[@]} == 0)) || exec lspci "$@"
  fi
}

# Creates a private staging file on the same filesystem as its destination
# Arguments: result variable name, destination path
# Outputs: sets the result variable; returns nonzero if mktemp fails
create_managed_temporary_path() {
  local result_name=$1
  local destination=$2
  local destination_directory=${destination%/*}
  local destination_name=${destination##*/}
  local generated_path

  [[ "${destination_directory}" != "${destination}" ]] \
    || destination_directory=.
  generated_path=$(mktemp \
    --tmpdir="${destination_directory}" \
    ".${destination_name}.XXXXXX") || return
  printf -v "${result_name}" '%s' "${generated_path}"
}

# Replaces a destination by rename, removing the staging file on failure
# Arguments: temporary path next to the destination, destination path
# Returns: nonzero if the rename fails
commit_managed_temporary_path() {
  local temporary_path=$1
  local destination=$2

  if ! mv --force --no-copy --no-target-directory -- \
    "${temporary_path}" "${destination}"; then
    rm --force -- "${temporary_path}"
    return 1
  fi
}

# Copies a host symlink target into the writable guest /etc overlay
# Arguments: name below FHS_ROOT/etc
materialize_etc_symlink() {
  local file_name=$1
  local path="${FHS_ROOT}/etc/${file_name}"
  local target
  local temporary_path

  [[ -L "${path}" ]] || return 0
  target=$(readlink --canonicalize -- "${path}" 2>/dev/null) || return 0
  if [[ -f "${target}" ]]; then
    create_managed_temporary_path temporary_path "${path}" || return
    if ! cp --preserve=mode --no-target-directory -- \
      "${target}" "${temporary_path}"; then
      rm --force -- "${temporary_path}"
      return 1
    fi
    commit_managed_temporary_path "${temporary_path}" "${path}"
  elif [[ -d "${target}" ]]; then
    rm --force -- "${path}" || return
    mkdir --parents -- "${path}" || return
    cp --archive --one-file-system -- "${target}/." "${path}/"
  fi
}

# Copies host /etc and prepares the declared writable stubs
# Globals: FHS_ROOT, ETC_SYMLINKS_TO_MATERIALIZE, ETC_STUB_DIRS, ETC_STUB_FILES
populate_etc_overlay() {
  local relative_path

  mkdir --parents -- "${FHS_ROOT}/etc" || return
  cp --archive --one-file-system -- /etc/. "${FHS_ROOT}/etc/" \
    2>/dev/null || true
  for relative_path in "${ETC_SYMLINKS_TO_MATERIALIZE[@]}"; do
    materialize_etc_symlink "${relative_path}" || return
  done
  for relative_path in "${ETC_STUB_DIRS[@]}"; do
    mkdir --parents -- "${FHS_ROOT}/etc/${relative_path}" || return
  done
  for relative_path in "${ETC_STUB_FILES[@]}"; do
    rm --force -- "${FHS_ROOT}/etc/${relative_path}" || return
    install \
      --mode="${ETC_STUB_FILE_MODE}" \
      --no-target-directory \
      -- \
      /dev/null \
      "${FHS_ROOT}/etc/${relative_path}" || return
  done
}

# Mirrors graphics manifests into the native loader and Pressure Vessel paths
# Arguments: extra manifests to copy into the implicit-layer directory
# Globals: Vulkan source/destination constants; requires nullglob
install_vulkan_metadata() {
  local extra_manifest
  local -a manifest_paths
  local source_directory
  local subdirectory

  mkdir --parents -- "${VULKAN_SHARE}" "${VULKAN_OVERRIDES}" || return
  for subdirectory in "${VULKAN_SUBDIRECTORIES[@]}"; do
    source_directory="${OPENGL_VULKAN_SHARE}/${subdirectory}"
    [[ -e "${source_directory}" ]] || continue
    rm --force --recursive --one-file-system --preserve-root=all -- \
      "${VULKAN_SHARE:?}/${subdirectory}" || return
    ln --symbolic --no-target-directory -- \
      "${source_directory}" \
      "${VULKAN_SHARE}/${subdirectory}" || return
    mkdir --parents -- "${VULKAN_OVERRIDES}/${subdirectory}" || return
    manifest_paths=("${source_directory}"/*.json)
    ((${#manifest_paths[@]} == 0)) || ln \
      --symbolic \
      --force \
      --no-dereference \
      --target-directory="${VULKAN_OVERRIDES}/${subdirectory}" \
      -- \
      "${manifest_paths[@]}" || return
  done

  (($# == 0)) && return
  mkdir --parents -- "${VULKAN_OVERRIDES}/implicit_layer.d" || return
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

# Installs a declarative map of relative destinations to symlink targets
# Arguments: destination root, associative array name, optional source root
# Returns: nonzero if a link cannot be installed
install_relative_links() {
  local root=$1
  local -n links=$2
  local source_root=${3:+${3%/}/}
  local relative_path

  for relative_path in "${!links[@]}"; do
    ln --symbolic --force --no-target-directory -- \
      "${source_root}${links[${relative_path}]}" \
      "${root}/${relative_path}" || return
  done
}

# Creates the declared directories below FHS_ROOT
# Arguments: paths relative to FHS_ROOT
create_fhs_directories() {
  local relative_path

  for relative_path in "$@"; do
    mkdir --parents -- "${FHS_ROOT}/${relative_path}" || return
  done
}

# Copies host directory contents into the writable guest FHS
# Arguments: paths relative to /; inaccessible host files are skipped
copy_host_fhs_directories() {
  local relative_path

  for relative_path in "$@"; do
    cp --archive --one-file-system -- \
      "/${relative_path}/." \
      "${FHS_ROOT}/${relative_path}/" \
      2>/dev/null || true
  done
}

# Pressure Vessel imports compiled locales from /usr/lib/locale, independently
# of LOCALE_ARCHIVE in the client environment. Expose the same NixOS data there
# when the host provides it; charmaps remain available for locale generation
install_host_locale_data() {
  local locale_directory
  local destination="${FHS_ROOT}/usr/lib/locale"

  [[ -f "${LOCALE_ARCHIVE_PATH}" ]] || return 0
  locale_directory=$(readlink --canonicalize -- \
    "${LOCALE_ARCHIVE_PATH%/*}") || return
  mkdir --parents -- "${FHS_ROOT}/usr/lib" || return
  rm --force --recursive --one-file-system --preserve-root=all -- \
    "${destination}" || return
  ln --symbolic --no-target-directory -- \
    "${locale_directory}" "${destination}"
}

# Binds the guest FHS directories over the inherited host paths
# Arguments: paths relative to FHS_ROOT; uses MOUNT_BASE_ARGS
bind_fhs_directories() {
  local relative_path

  for relative_path in "$@"; do
    mount \
      "${MOUNT_BASE_ARGS[@]}" \
      --bind \
      "${FHS_ROOT}/${relative_path}" \
      "/${relative_path}" || return
  done
}

unset -f \
  declare_readonly_array_default
