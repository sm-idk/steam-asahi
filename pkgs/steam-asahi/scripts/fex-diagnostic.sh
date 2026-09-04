#!/usr/bin/env bash
# shellcheck shell=bash
#
# Runs a user-requested diagnostic command inside the configured FEX guest.

set -o errexit
set -o nounset
set -o pipefail

: "${COMMON_SCRIPT:=${BASH_SOURCE[0]%/*}/../../scripts/common.sh}"
# shellcheck source=/dev/null
source "${COMMON_SCRIPT}"
readonly COMMON_SCRIPT

main() {
  (( $# == 1 )) || {
    printf '%s\n' 'usage: fex-diagnostic.sh command' >&2
    return 2
  }

  prepend_colon_path PATH "${GUEST_PATH_ENTRIES[@]}"
  unset -v "${HOST_LOCALE_VARIABLES[@]}"
  export LC_ALL="${C_LOCALE}"
  export LANG="${C_LOCALE}"

  exec "${BASH}" -c "$1"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
