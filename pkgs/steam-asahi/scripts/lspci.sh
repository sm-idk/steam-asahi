#!/usr/bin/env bash
# shellcheck shell=bash
#
# Hides pciutils errors on Apple Silicon systems that have no PCI devices.

set -o errexit
set -o nounset
set -o pipefail

main() {
  local device_path

  if [[ -d /sys/bus/pci/devices ]]; then
    for device_path in /sys/bus/pci/devices/*; do
      [[ -e "${device_path}" ]] && exec lspci "$@"
    done
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
