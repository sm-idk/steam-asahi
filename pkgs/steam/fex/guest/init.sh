#!/usr/bin/env bash
# shellcheck shell=bash
#
# Builds the temporary FHS layout required by Steam and Pressure Vessel

set -o errexit
set -o nounset
set -o pipefail

: "${COMMON_SCRIPT:=${BASH_SOURCE[0]%/*}/../../../../src/guest/common.sh}"
# shellcheck source=/dev/null
source "${COMMON_SCRIPT}"
readonly COMMON_SCRIPT

readonly -a REQUIRED_CONFIGURATION_VARIABLES=(
  BASH_BIN
  ENV_BIN
  FUSERMOUNT
  FUSERMOUNT3
  GLIBC_I18N
  LSB_RELEASE
  LSPCI
  PACTL
  SH_BIN
  ZENITY
)
require_configuration_variables "${REQUIRED_CONFIGURATION_VARIABLES[@]}"

# Consumed by the shared install_relative_links helper through a nameref
# shellcheck disable=SC2034
readonly -A FHS_COMMAND_LINKS=(
  ["bin/bash"]="${BASH_BIN}"
  ["bin/lsb_release"]="${LSB_RELEASE}"
  ["bin/lspci"]="${LSPCI}"
  ["bin/pactl"]="${PACTL}"
  ["bin/sh"]="${SH_BIN}"
  ["bin/zenity"]="${ZENITY}"
  ["usr/bin/env"]="${ENV_BIN}"
  ["usr/bin/lsb_release"]="${LSB_RELEASE}"
  ["usr/bin/pactl"]="${PACTL}"
  ["usr/bin/zenity"]="${ZENITY}"
)
# shellcheck disable=SC2034
readonly -A FHS_INTERNAL_LINKS=(
  ["usr/bin/lspci"]=bin/lspci
)
readonly -a FHS_BIND_DIRECTORIES=(
  bin
  usr
)
readonly -a FHS_COPY_DIRECTORIES=(
  bin
  usr
)
readonly -a FHS_CREATE_DIRECTORIES=(
  bin
  usr
  usr/bin
  usr/lib
  usr/lib64
)
readonly -A FUSERMOUNT_WRAPPERS=(
  ["fusermount"]="${FUSERMOUNT}"
  ["fusermount3"]="${FUSERMOUNT3}"
)
# This private mount contains only the directory and two small helper binaries
FUSERMOUNT_TMPFS_OPTIONS=nodev,noatime,nosymfollow,exec,suid
FUSERMOUNT_TMPFS_OPTIONS+=,mode=0755,size=4M,nr_inodes=64
readonly FUSERMOUNT_TMPFS_OPTIONS

install_fhs_commands() {
  install_relative_links "${FHS_ROOT}" FHS_COMMAND_LINKS || return
  install_relative_links "${FHS_ROOT}" FHS_INTERNAL_LINKS "${FHS_ROOT}"
}

install_etc_overlay() {
  populate_etc_overlay || return
  mount "${MOUNT_BASE_ARGS[@]}" --bind "${FHS_ROOT}/etc" /etc
}

install_fusermount_wrappers() {
  local name
  local wrappers_root=${WRAPPERS_BIN_DIRECTORY%/*}

  mount \
    "${MOUNT_BASE_ARGS[@]}" \
    --mkdir=0755 \
    --types=tmpfs \
    --options="${FUSERMOUNT_TMPFS_OPTIONS}" \
    tmpfs \
    "${wrappers_root}" || return
  mkdir --parents -- "${WRAPPERS_BIN_DIRECTORY}" || return
  for name in "${!FUSERMOUNT_WRAPPERS[@]}"; do
    install \
      --group=root \
      --mode=u=srx,g=x,o=x \
      --owner=root \
      --no-target-directory \
      -- \
      "${FUSERMOUNT_WRAPPERS[${name}]}" \
      "${WRAPPERS_BIN_DIRECTORY}/${name}" || return
  done
}

main() {
  require_muvm_guest || return

  # /usr is read-only in the guest. Construct a writable FHS tree in tmpfs,
  # then bind it over the inherited host directories
  create_fhs_directories "${FHS_CREATE_DIRECTORIES[@]}" || return
  copy_host_fhs_directories "${FHS_COPY_DIRECTORIES[@]}" || return

  install_fhs_commands || return

  # Pressure Vessel generates locales from glibc's charmaps when needed
  mkdir --parents -- "${FHS_ROOT}/usr/share" || return
  rm --force --recursive --one-file-system --preserve-root=all -- \
    "${FHS_ROOT}/usr/share/i18n" || return
  ln --symbolic --no-target-directory -- \
    "${GLIBC_I18N}" \
    "${FHS_ROOT}/usr/share/i18n" || return

  # Steam creates overlay and Fossilize layer metadata in users' XDG trees
  install_vulkan_metadata \
    /home/*/.local/share/vulkan/implicit_layer.d/steam*.json || return
  bind_fhs_directories "${FHS_BIND_DIRECTORIES[@]}" || return
  install_etc_overlay || return
  install_fusermount_wrappers
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  shopt -s array_expand_once inherit_errexit nullglob
  main "$@"
fi
