#!/usr/bin/env bash
# shellcheck shell=bash
#
# Builds the temporary FHS layout required by Steam and Pressure Vessel.

set -o errexit
set -o nounset
set -o pipefail

: "${COMMON_SCRIPT:=${BASH_SOURCE[0]%/*}/../../scripts/common.sh}"
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
# This private mount contains only the directory and two small helper binaries.
readonly FUSERMOUNT_TMPFS_OPTIONS=\
'nodev,noatime,nosymfollow,exec,suid,mode=0755,size=4M,nr_inodes=64'

install_fhs_commands() {
  local relative_path

  for relative_path in "${!FHS_COMMAND_LINKS[@]}"; do
    ln --symbolic --force --no-target-directory -- \
      "${FHS_COMMAND_LINKS[${relative_path}]}" \
      "${FHS_ROOT}/${relative_path}"
  done
  for relative_path in "${!FHS_INTERNAL_LINKS[@]}"; do
    ln --symbolic --force --no-target-directory -- \
      "${FHS_ROOT}/${FHS_INTERNAL_LINKS[${relative_path}]}" \
      "${FHS_ROOT}/${relative_path}"
  done
}

install_etc_overlay() {
  populate_etc_overlay
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
    "${wrappers_root}"
  mkdir -p -- "${WRAPPERS_BIN_DIRECTORY}"
  for name in "${!FUSERMOUNT_WRAPPERS[@]}"; do
    install \
      --group=root \
      --mode=u=srx,g=x,o=x \
      --owner=root \
      --no-target-directory \
      -- \
      "${FUSERMOUNT_WRAPPERS[${name}]}" \
      "${WRAPPERS_BIN_DIRECTORY}/${name}"
  done
}

main() {
  # /usr is read-only in the guest. Construct a writable FHS tree in tmpfs,
  # then bind it over the inherited host directories.
  create_fhs_directories "${FHS_CREATE_DIRECTORIES[@]}"
  copy_host_fhs_directories "${FHS_COPY_DIRECTORIES[@]}"

  install_fhs_commands

  # Pressure Vessel generates locales from glibc's charmaps when needed.
  mkdir -p -- "${FHS_ROOT}/usr/share"
  rm --force --recursive --one-file-system --preserve-root=all -- \
    "${FHS_ROOT}/usr/share/i18n"
  ln --symbolic --no-target-directory -- \
    "${GLIBC_I18N}" \
    "${FHS_ROOT}/usr/share/i18n"

  # Steam creates overlay and Fossilize layer metadata in users' XDG trees.
  install_vulkan_metadata \
    /home/*/.local/share/vulkan/implicit_layer.d/steam*.json
  bind_fhs_directories "${FHS_BIND_DIRECTORIES[@]}"
  install_etc_overlay
  install_fusermount_wrappers
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  shopt -s array_expand_once inherit_errexit nullglob
  main "$@"
fi
