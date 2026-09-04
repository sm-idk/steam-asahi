#!/usr/bin/env bash
# shellcheck shell=bash
#
# Builds the temporary FHS layout required by Valve's ARM64 Steam binaries.

set -o errexit
set -o nounset
set -o pipefail

: "${COMMON_SCRIPT:=${BASH_SOURCE[0]%/*}/../../scripts/common.sh}"
# shellcheck source=/dev/null
source "${COMMON_SCRIPT}"
readonly COMMON_SCRIPT

readonly -a REQUIRED_CONFIGURATION_VARIABLES=(
  BASH_BIN
  COREUTILS_BIN
  GETOPT
  GLIBC_BIN
  GLIBC_I18N
  LD_LINUX
  LDCONFIG
  LSB_RELEASE
  LSOF
  LSPCI
  NATIVE_RUNTIME
  SH_BIN
  TASKSET
  TZDATA_ZONEINFO
  X11_LOCALE
  XDG_OPEN
  XDG_USER_DIR
  ZENITY
)
require_configuration_variables "${REQUIRED_CONFIGURATION_VARIABLES[@]}"

: "${EXTRA_COMMAND_DIRS[*]:?internal configuration was not injected}"
readonly -a EXTRA_COMMAND_DIRS

readonly -a LIBRARY_DIRECTORIES=(
  "${FHS_ROOT}/lib"
  "${FHS_ROOT}/lib/aarch64-linux-gnu"
  "${FHS_ROOT}/usr/lib"
  "${FHS_ROOT}/usr/lib64"
  "${FHS_ROOT}/usr/lib/aarch64-linux-gnu"
)
readonly -a COMMAND_DIRECTORIES=(
  "${COREUTILS_BIN}"
  "${GLIBC_BIN}"
  "${EXTRA_COMMAND_DIRS[@]}"
)
readonly -a FHS_BIND_DIRECTORIES=(
  bin
  lib
  usr
)
readonly -a FHS_COPY_DIRECTORIES=(
  bin
  usr
)
readonly -a FHS_CREATE_DIRECTORIES=(
  bin
  lib/aarch64-linux-gnu
  usr/bin
)
readonly TEMP_DIRECTORY_MODE=1777
readonly -A FHS_COMMAND_LINKS=(
  ["bin/bash"]="${BASH_BIN}"
  ["bin/getopt"]="${GETOPT}"
  ["bin/lsb_release"]="${LSB_RELEASE}"
  ["bin/lsof"]="${LSOF}"
  ["bin/lspci"]="${LSPCI}"
  ["bin/sh"]="${SH_BIN}"
  ["bin/taskset"]="${TASKSET}"
  ["bin/zenity"]="${ZENITY}"
  ["usr/bin/getopt"]="${GETOPT}"
  ["usr/bin/lsb_release"]="${LSB_RELEASE}"
  ["usr/bin/lsof"]="${LSOF}"
  ["usr/bin/taskset"]="${TASKSET}"
  ["usr/bin/xdg-open"]="${XDG_OPEN}"
  ["usr/bin/xdg-user-dir"]="${XDG_USER_DIR}"
  ["usr/bin/zenity"]="${ZENITY}"
)
readonly -A FHS_INTERNAL_LINKS=(
  ["usr/bin/lspci"]=bin/lspci
)
readonly -A SHARED_DATA_LINKS=(
  ["X11/locale"]="${X11_LOCALE}"
  ["i18n"]="${GLIBC_I18N}"
  ["zoneinfo"]="${TZDATA_ZONEINFO}"
)

link_commands() {
  local command_directory
  local destination=$1
  local -a command_paths

  for command_directory in "${COMMAND_DIRECTORIES[@]}"; do
    command_paths=("${command_directory}"/*)
    if (( ${#command_paths[@]} == 0 )); then
      printf 'ERROR: no commands found under %s\n' \
        "${command_directory}" >&2
      return 1
    fi
    ln \
      --symbolic \
      --force \
      --target-directory="${destination}" \
      -- \
      "${command_paths[@]}"
  done
}

install_fhs_commands() {
  local root=$1
  local relative_path

  link_commands "${root}/bin"
  link_commands "${root}/usr/bin"
  for relative_path in "${!FHS_COMMAND_LINKS[@]}"; do
    ln --symbolic --force --no-target-directory -- \
      "${FHS_COMMAND_LINKS[${relative_path}]}" \
      "${root}/${relative_path}"
  done
  for relative_path in "${!FHS_INTERNAL_LINKS[@]}"; do
    ln --symbolic --force --no-target-directory -- \
      "${root}/${FHS_INTERNAL_LINKS[${relative_path}]}" \
      "${root}/${relative_path}"
  done
}

# Populates the guest FHS with the dynamic linker and native Nix libraries.
install_native_libraries() {
  local directory
  local -a library_paths=("${NATIVE_RUNTIME}"/lib/*)

  # Steam's own runtime takes precedence later. This fallback provides the
  # native dynamic linker and libraries needed by initial client probes.
  ln --symbolic --force --no-target-directory -- \
    "${LD_LINUX}" \
    "${FHS_ROOT}/lib/ld-linux-aarch64.so.1"
  if (( ${#library_paths[@]} == 0 )); then
    printf 'ERROR: no native libraries found under %s/lib\n' \
      "${NATIVE_RUNTIME}" >&2
    return 1
  fi
  for directory in "${LIBRARY_DIRECTORIES[@]}"; do
    ln \
      --symbolic \
      --force \
      --target-directory="${directory}" \
      -- \
      "${library_paths[@]}"
  done
}

# Exposes immutable locale, timezone, and X11 data in the temporary FHS.
install_shared_data() {
  local relative_path
  local share_directory="${FHS_ROOT}/usr/share"

  mkdir -p -- "${share_directory}/X11"
  for relative_path in "${!SHARED_DATA_LINKS[@]}"; do
    rm --force --recursive --one-file-system --preserve-root=all -- \
      "${share_directory:?}/${relative_path}"
    ln --symbolic --no-target-directory -- \
      "${SHARED_DATA_LINKS[${relative_path}]}" \
      "${share_directory}/${relative_path}"
  done
}

# Copies host identity files into a writable /etc and updates the guest user's
# home directory when the launcher requests isolated state.
install_etc_overlay() {
  local account_name
  local directory
  local entry_uid
  local gecos
  local gid
  local home
  local login_shell
  local password

  populate_etc_overlay

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
    mv \
      --force \
      --no-copy \
      --no-target-directory \
      -- \
      "${FHS_ROOT}/etc/passwd.new" \
      "${FHS_ROOT}/etc/passwd"
  fi

  for directory in "${LIBRARY_DIRECTORIES[@]}"; do
    printf '%s\n' "${directory#"${FHS_ROOT}"}"
  done >"${FHS_ROOT}/etc/ld.so.conf"
  printf '%s\n' "${OPENGL_DRIVER_ROOT}/lib" \
    >>"${FHS_ROOT}/etc/ld.so.conf"
  mount "${MOUNT_BASE_ARGS[@]}" --bind "${FHS_ROOT}/etc" /etc
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
  chmod "${TEMP_DIRECTORY_MODE}" -- "${FHS_ROOT}/var/tmp"
  ln --symbolic --force --no-target-directory -- \
    /run \
    "${FHS_ROOT}/var/run"
  # The unprivileged guest cannot add a mountpoint to inherited /var, but can
  # bind over the existing /var mountpoint.
  mount "${MOUNT_BASE_ARGS[@]}" --bind "${FHS_ROOT}/var" /var
  "${LDCONFIG}" -X -f /etc/ld.so.conf -C /var/cache/ldconfig/ld.so.cache
  rm -f -- /etc/ld.so.cache
  ln --symbolic --no-target-directory -- \
    /var/cache/ldconfig/ld.so.cache \
    /etc/ld.so.cache
}

main() {
  # None of the installation globs depend on lexical order.
  local -r GLOBSORT=nosort

  # Valve's binaries request /lib/ld-linux-aarch64.so.1 and assume a
  # conventional distro filesystem. These guest-only tmpfs mounts never modify
  # host paths.
  create_fhs_directories "${FHS_CREATE_DIRECTORIES[@]}"
  copy_host_fhs_directories "${FHS_COPY_DIRECTORIES[@]}"
  mkdir -p -- "${FHS_ROOT}/usr/bin" "${LIBRARY_DIRECTORIES[@]}"
  install_fhs_commands "${FHS_ROOT}"
  install_native_libraries
  install_shared_data
  install_vulkan_metadata

  bind_fhs_directories "${FHS_BIND_DIRECTORIES[@]}"
  install_etc_overlay
  install_var_overlay
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  shopt -s array_expand_once inherit_errexit nullglob
  main "$@"
fi
