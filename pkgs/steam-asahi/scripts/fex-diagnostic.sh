#!/usr/bin/env bash
# shellcheck shell=bash
#
# Runs a user-requested diagnostic command inside the configured FEX guest.

set -o errexit
set -o nounset
set -o pipefail

main() {
  (( $# == 1 )) || {
    printf '%s\n' 'usage: fex-diagnostic.sh command' >&2
    return 2
  }

  export PATH="/usr/local/bin:/usr/bin:/bin${PATH:+:${PATH}}"
  unset \
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
  export LC_ALL=C.UTF-8
  export LANG=C.UTF-8

  exec "${BASH}" -c "${1}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
