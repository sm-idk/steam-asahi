#!/usr/bin/env bash
# shellcheck shell=bash
#
# Configures the x86 FEX environment and starts Steam with its original argv

set -o errexit
set -o nounset
set -o pipefail

: "${COMMON_SCRIPT:=${BASH_SOURCE[0]%/*}/../../scripts/common.sh}"
# shellcheck source=/dev/null
source "${COMMON_SCRIPT}"
readonly COMMON_SCRIPT
require_configuration_variables STEAM_ASAHI_GUEST_UID

main() {
  (($# > 0)) || {
    printf '%s\n' 'usage: fex-steam.sh command [arguments...]' >&2
    return 2
  }

  configure_guest_environment "${STEAM_ASAHI_GUEST_UID}"

  exec "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  shopt -s array_expand_once
  main "$@"
fi
