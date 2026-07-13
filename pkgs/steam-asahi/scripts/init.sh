#!/usr/bin/env bash
# shellcheck shell=bash
#
# Builds the temporary FHS layout required by Steam and Pressure Vessel.

set -o errexit
set -o nounset
set -o pipefail

: "${BASH_BIN:?internal configuration was not injected}"
: "${ENV_BIN:?internal configuration was not injected}"
: "${FUSERMOUNT:?internal configuration was not injected}"
: "${FUSERMOUNT3:?internal configuration was not injected}"
: "${GLIBC_I18N:?internal configuration was not injected}"
: "${LSB_RELEASE:?internal configuration was not injected}"
: "${LSPCI:?internal configuration was not injected}"
: "${PACTL:?internal configuration was not injected}"
: "${SH_BIN:?internal configuration was not injected}"
: "${ZENITY:?internal configuration was not injected}"

readonly BASH_BIN
readonly ENV_BIN
readonly -a ETC_STUB_DIRS
readonly -a ETC_STUB_FILES
readonly -a ETC_SYMLINKS_TO_MATERIALIZE
readonly FUSERMOUNT
readonly FUSERMOUNT3
readonly GLIBC_I18N
readonly LSB_RELEASE
readonly LSPCI
readonly PACTL
readonly SH_BIN
readonly ZENITY

readonly FHS_ROOT=/run/fhs
readonly PRESSURE_VESSEL_SHARE=\
"${FHS_ROOT}/usr/lib/pressure-vessel/overrides/share"
readonly VULKAN_SHARE="${FHS_ROOT}/usr/share/vulkan"
readonly VULKAN_OVERRIDES="${PRESSURE_VESSEL_SHARE}/vulkan"

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

install_fhs_commands() {
  ln -sf -- "${BASH_BIN}" "${FHS_ROOT}/bin/bash"
  ln -sf -- "${SH_BIN}" "${FHS_ROOT}/bin/sh"
  ln -sf -- "${LSPCI}" "${FHS_ROOT}/bin/lspci"
  ln -sf -- "${PACTL}" "${FHS_ROOT}/bin/pactl"
  ln -sf -- "${LSB_RELEASE}" "${FHS_ROOT}/bin/lsb_release"
  ln -sf -- "${ZENITY}" "${FHS_ROOT}/bin/zenity"

  ln -sf -- "${ENV_BIN}" "${FHS_ROOT}/usr/bin/env"
  ln -sf -- "${FHS_ROOT}/bin/lspci" "${FHS_ROOT}/usr/bin/lspci"
  ln -sf -- "${PACTL}" "${FHS_ROOT}/usr/bin/pactl"
  ln -sf -- "${LSB_RELEASE}" "${FHS_ROOT}/usr/bin/lsb_release"
  ln -sf -- "${ZENITY}" "${FHS_ROOT}/usr/bin/zenity"
}

# Mirrors Vulkan manifests into the locations used by the native loader and
# Pressure Vessel.
install_vulkan_metadata() {
  local json
  local layer
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

  # Steam creates overlay and Fossilize layer metadata in users' XDG trees.
  mkdir -p -- "${VULKAN_OVERRIDES}/implicit_layer.d"
  for layer in /home/*/.local/share/vulkan/implicit_layer.d/steam*.json; do
    if [[ -f "${layer}" ]]; then
      cp -f -- \
        "${layer}" \
        "${VULKAN_OVERRIDES}/implicit_layer.d/" \
        2>/dev/null \
        || true
    fi
  done
}

install_etc_overlay() {
  local directory
  local file_name

  mkdir -p -- "${FHS_ROOT}/etc"
  cp -a -- /etc/. "${FHS_ROOT}/etc/" 2>/dev/null || true

  for file_name in "${ETC_SYMLINKS_TO_MATERIALIZE[@]}"; do
    materialize_etc_symlink "${file_name}"
  done
  for directory in "${ETC_STUB_DIRS[@]}"; do
    mkdir -p -- "${FHS_ROOT}/etc/${directory}"
  done
  for file_name in "${ETC_STUB_FILES[@]}"; do
    touch -- "${FHS_ROOT}/etc/${file_name}"
  done

  mount --bind "${FHS_ROOT}/etc" /etc
}

install_fusermount_wrappers() {
  mkdir -p -- /run/wrappers
  mount -t tmpfs -o exec,suid tmpfs /run/wrappers
  mkdir -p -- /run/wrappers/bin
  cp -- "${FUSERMOUNT}" /run/wrappers/bin/fusermount
  cp -- "${FUSERMOUNT3}" /run/wrappers/bin/fusermount3
  chown root:root -- \
    /run/wrappers/bin/fusermount \
    /run/wrappers/bin/fusermount3
  chmod u=srx,g=x,o=x -- \
    /run/wrappers/bin/fusermount \
    /run/wrappers/bin/fusermount3
}

main() {
  # /usr is read-only in the guest. Construct a writable FHS tree in tmpfs,
  # then bind it over the inherited host directories.
  mkdir -p -- "${FHS_ROOT}/bin" "${FHS_ROOT}/usr"
  cp -a -- /bin/. "${FHS_ROOT}/bin/" 2>/dev/null || true
  cp -a -- /usr/. "${FHS_ROOT}/usr/" 2>/dev/null || true
  mkdir -p -- \
    "${FHS_ROOT}/usr/bin" \
    "${FHS_ROOT}/usr/lib" \
    "${FHS_ROOT}/usr/lib64"

  install_fhs_commands

  # Pressure Vessel generates locales from glibc's charmaps when needed.
  mkdir -p -- "${FHS_ROOT}/usr/share"
  rm -rf -- "${FHS_ROOT}/usr/share/i18n"
  ln -s -- "${GLIBC_I18N}" "${FHS_ROOT}/usr/share/i18n"

  install_vulkan_metadata
  mount --bind "${FHS_ROOT}/bin" /bin
  mount --bind "${FHS_ROOT}/usr" /usr
  install_etc_overlay
  install_fusermount_wrappers
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
