#!/usr/bin/env bash
# shellcheck shell=bash
#
# Builds the temporary FHS layout required by Valve's ARM64 Steam binaries.

set -o errexit
set -o nounset
set -o pipefail

: "${BASH_BIN:?internal configuration was not injected}"
: "${COREUTILS_BIN:?internal configuration was not injected}"
: "${EXTRA_COMMAND_DIRS[*]:?internal configuration was not injected}"
: "${GETOPT:?internal configuration was not injected}"
: "${GLIBC_BIN:?internal configuration was not injected}"
: "${GLIBC_I18N:?internal configuration was not injected}"
: "${LD_LINUX:?internal configuration was not injected}"
: "${LDCONFIG:?internal configuration was not injected}"
: "${LSB_RELEASE:?internal configuration was not injected}"
: "${LSOF:?internal configuration was not injected}"
: "${LSPCI:?internal configuration was not injected}"
: "${NATIVE_RUNTIME:?internal configuration was not injected}"
: "${SH_BIN:?internal configuration was not injected}"
: "${TASKSET:?internal configuration was not injected}"
: "${TZDATA_ZONEINFO:?internal configuration was not injected}"
: "${X11_LOCALE:?internal configuration was not injected}"
: "${XDG_OPEN:?internal configuration was not injected}"
: "${XDG_USER_DIR:?internal configuration was not injected}"
: "${ZENITY:?internal configuration was not injected}"

readonly BASH_BIN
readonly COREUTILS_BIN
readonly -a EXTRA_COMMAND_DIRS
readonly -a ETC_STUB_DIRS
readonly -a ETC_STUB_FILES
readonly -a ETC_SYMLINKS_TO_MATERIALIZE
readonly GETOPT
readonly GLIBC_BIN
readonly GLIBC_I18N
readonly LD_LINUX
readonly LDCONFIG
readonly LSB_RELEASE
readonly LSOF
readonly LSPCI
readonly NATIVE_RUNTIME
readonly SH_BIN
readonly TASKSET
readonly TZDATA_ZONEINFO
readonly X11_LOCALE
readonly XDG_OPEN
readonly XDG_USER_DIR
readonly ZENITY

readonly FHS_ROOT=/run/fhs
readonly -a LIBRARY_DIRECTORIES=(
  "${FHS_ROOT}/lib"
  "${FHS_ROOT}/lib/aarch64-linux-gnu"
  "${FHS_ROOT}/usr/lib"
  "${FHS_ROOT}/usr/lib64"
  "${FHS_ROOT}/usr/lib/aarch64-linux-gnu"
)
readonly VULKAN_SHARE="${FHS_ROOT}/usr/share/vulkan"
readonly PRESSURE_VESSEL_SHARE=\
"${FHS_ROOT}/usr/lib/pressure-vessel/overrides/share"
readonly VULKAN_OVERRIDES="${PRESSURE_VESSEL_SHARE}/vulkan"

link_commands() {
  local command_directory
  local command_path
  local destination=$1

  for command_directory in \
    "${COREUTILS_BIN}" \
    "${GLIBC_BIN}" \
    "${EXTRA_COMMAND_DIRS[@]}"; do
    for command_path in "${command_directory}"/*; do
      ln -sf -- \
        "${command_path}" \
        "${destination}/$(basename -- "${command_path}")"
    done
  done
}

install_fhs_commands() {
  local root=$1

  link_commands "${root}/bin"
  ln -sf -- "${BASH_BIN}" "${root}/bin/bash"
  ln -sf -- "${GETOPT}" "${root}/bin/getopt"
  ln -sf -- "${SH_BIN}" "${root}/bin/sh"
  ln -sf -- "${LSPCI}" "${root}/bin/lspci"
  ln -sf -- "${LSB_RELEASE}" "${root}/bin/lsb_release"
  ln -sf -- "${LSOF}" "${root}/bin/lsof"
  ln -sf -- "${TASKSET}" "${root}/bin/taskset"
  ln -sf -- "${ZENITY}" "${root}/bin/zenity"

  link_commands "${root}/usr/bin"
  ln -sf -- "${GETOPT}" "${root}/usr/bin/getopt"
  ln -sf -- "${root}/bin/lspci" "${root}/usr/bin/lspci"
  ln -sf -- "${LSB_RELEASE}" "${root}/usr/bin/lsb_release"
  ln -sf -- "${LSOF}" "${root}/usr/bin/lsof"
  ln -sf -- "${TASKSET}" "${root}/usr/bin/taskset"
  ln -sf -- "${XDG_OPEN}" "${root}/usr/bin/xdg-open"
  ln -sf -- "${XDG_USER_DIR}" "${root}/usr/bin/xdg-user-dir"
  ln -sf -- "${ZENITY}" "${root}/usr/bin/zenity"
}

materialize_etc_symlink() {
  local file_name=$1
  local path="${FHS_ROOT}/etc/${file_name}"
  local target

  [[ -L "${path}" ]] || return 0
  target=$(readlink -f -- "${path}" 2>/dev/null) || return 0
  rm -f -- "${path}"

  if [[ -f "${target}" ]]; then
    cp -- "${target}" "${path}"
  elif [[ -d "${target}" ]]; then
    mkdir -p -- "${path}"
    cp -a -- "${target}/." "${path}/"
  fi
}

# Populates the guest FHS with the dynamic linker and native Nix libraries.
install_native_libraries() {
  local directory
  local library_name
  local path

  # Steam's own runtime takes precedence later. This fallback provides the
  # native dynamic linker and libraries needed by initial client probes.
  ln -sf -- "${LD_LINUX}" "${FHS_ROOT}/lib/ld-linux-aarch64.so.1"
  for path in "${NATIVE_RUNTIME}"/lib/*; do
    [[ -e "${path}" ]] || continue
    library_name=$(basename -- "${path}")
    for directory in "${LIBRARY_DIRECTORIES[@]}"; do
      ln -sfn -- "${path}" "${directory}/${library_name}"
    done
  done
}

# Exposes immutable locale, timezone, and X11 data in the temporary FHS.
install_shared_data() {
  local share_directory="${FHS_ROOT}/usr/share"

  mkdir -p -- "${share_directory}/X11"
  rm -rf -- \
    "${share_directory}/i18n" \
    "${share_directory}/X11/locale" \
    "${share_directory}/zoneinfo"
  ln -s -- "${GLIBC_I18N}" "${share_directory}/i18n"
  ln -s -- "${X11_LOCALE}" "${share_directory}/X11/locale"
  ln -s -- "${TZDATA_ZONEINFO}" "${share_directory}/zoneinfo"
}

# Mirrors Asahi Vulkan manifests into the locations used by the native loader
# and Pressure Vessel.
install_vulkan_metadata() {
  local json
  local source_directory
  local subdirectory

  mkdir -p -- "${VULKAN_SHARE}" "${VULKAN_OVERRIDES}"
  for subdirectory in icd.d explicit_layer.d implicit_layer.d; do
    source_directory="/run/opengl-driver/share/vulkan/${subdirectory}"
    [[ -e "${source_directory}" ]] || continue
    rm -rf -- "${VULKAN_SHARE:?}/${subdirectory}"
    ln -s -- "${source_directory}" "${VULKAN_SHARE}/${subdirectory}"
    mkdir -p -- "${VULKAN_OVERRIDES}/${subdirectory}"
    for json in "${source_directory}"/*.json; do
      if [[ -e "${json}" ]]; then
        ln -sf -- "${json}" "${VULKAN_OVERRIDES}/${subdirectory}/"
      fi
    done
  done
}

# Copies host identity files into a writable /etc and updates the guest user's
# home directory when the launcher requests isolated state.
install_etc_overlay() {
  local account_name
  local directory
  local entry_uid
  local file_name
  local gecos
  local gid
  local home
  local login_shell
  local password

  mkdir -p -- "${FHS_ROOT}/etc"
  cp -a -- /etc/. "${FHS_ROOT}/etc/" 2>/dev/null || true
  for file_name in "${ETC_SYMLINKS_TO_MATERIALIZE[@]}"; do
    materialize_etc_symlink "${file_name}"
  done

  # HOME alone is insufficient for isolated Steam state because parts of the
  # client consult getpwuid(). Mirror the requested guest HOME in passwd.
  if [[ -n "${STEAM_ASAHI_GUEST_HOME:-}" \
    && -n "${STEAM_ASAHI_GUEST_UID:-}" ]]; then
    while IFS=: read -r \
      account_name password entry_uid gid gecos home login_shell; do
      if [[ "${entry_uid}" == "${STEAM_ASAHI_GUEST_UID}" ]]; then
        home=${STEAM_ASAHI_GUEST_HOME}
      fi
      printf '%s:%s:%s:%s:%s:%s:%s\n' \
        "${account_name}" "${password}" "${entry_uid}" "${gid}" \
        "${gecos}" "${home}" "${login_shell}"
    done <"${FHS_ROOT}/etc/passwd" >"${FHS_ROOT}/etc/passwd.new"
    mv -- "${FHS_ROOT}/etc/passwd.new" "${FHS_ROOT}/etc/passwd"
  fi

  for directory in "${ETC_STUB_DIRS[@]}"; do
    mkdir -p -- "${FHS_ROOT}/etc/${directory}"
  done
  for file_name in "${ETC_STUB_FILES[@]}"; do
    touch -- "${FHS_ROOT}/etc/${file_name}"
  done
  cat >"${FHS_ROOT}/etc/ld.so.conf" <<'EOF'
/lib
/lib/aarch64-linux-gnu
/usr/lib
/usr/lib64
/usr/lib/aarch64-linux-gnu
/run/opengl-driver/lib
EOF
  mount --bind "${FHS_ROOT}/etc" /etc
}

# Builds the writable /var tree and generates the library cache used by
# libcapsule when it imports the host graphics stack.
install_var_overlay() {
  # libcapsule consults Debian's auxiliary cache location while importing host
  # graphics libraries. NixOS has no cache, so construct one in the guest FHS.
  mkdir -p -- \
    "${FHS_ROOT}/var/cache/ldconfig" \
    "${FHS_ROOT}/var/lib" \
    "${FHS_ROOT}/var/log" \
    "${FHS_ROOT}/var/tmp"
  chmod 1777 -- "${FHS_ROOT}/var/tmp"
  ln -sfn -- /run "${FHS_ROOT}/var/run"
  # The unprivileged guest cannot add a mountpoint to inherited /var, but can
  # bind over the existing /var mountpoint.
  mount --bind "${FHS_ROOT}/var" /var
  "${LDCONFIG}" -X -f /etc/ld.so.conf -C /var/cache/ldconfig/ld.so.cache
  rm -f -- /etc/ld.so.cache
  ln -s -- /var/cache/ldconfig/ld.so.cache /etc/ld.so.cache
}

main() {
  # Valve's binaries request /lib/ld-linux-aarch64.so.1 and assume a
  # conventional distro filesystem. These guest-only tmpfs mounts never modify
  # host paths.
  mkdir -p -- \
    "${FHS_ROOT}/bin" \
    "${FHS_ROOT}/lib/aarch64-linux-gnu" \
    "${FHS_ROOT}/usr/bin"
  cp -a -- /bin/. "${FHS_ROOT}/bin/" 2>/dev/null || true
  cp -a -- /usr/. "${FHS_ROOT}/usr/" 2>/dev/null || true
  mkdir -p -- "${FHS_ROOT}/usr/bin" "${LIBRARY_DIRECTORIES[@]}"
  install_fhs_commands "${FHS_ROOT}"
  install_native_libraries
  install_shared_data
  install_vulkan_metadata

  mount --bind "${FHS_ROOT}/bin" /bin
  mount --bind "${FHS_ROOT}/lib" /lib
  mount --bind "${FHS_ROOT}/usr" /usr
  install_etc_overlay
  install_var_overlay
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
