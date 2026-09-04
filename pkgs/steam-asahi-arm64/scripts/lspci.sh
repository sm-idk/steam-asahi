#!/usr/bin/env bash
# shellcheck shell=bash
#
# Hides pciutils errors on Apple Silicon systems that have no PCI devices.

set -o errexit
set -o nounset
set -o pipefail

: "${COMMON_SCRIPT:=${BASH_SOURCE[0]%/*}/../../scripts/common.sh}"
# shellcheck source=/dev/null
source "${COMMON_SCRIPT}"
readonly COMMON_SCRIPT

main() {
  run_lspci_if_devices_exist "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  shopt -s nullglob
  main "$@"
fi
