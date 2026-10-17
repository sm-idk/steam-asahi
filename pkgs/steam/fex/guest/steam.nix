{ lib, ... }:
let
  shell = import ../../../../lib/guest/shell.nix { inherit lib; };
in

''
  # shellcheck shell=bash
  #
  # Configures the x86 FEX environment and starts Steam with its original argv

  : "''${STEAM_ASAHI_GUEST_UID:?guest UID was not provided}"

  main() {
    (($# > 0)) || {
      printf '%s\n' 'usage: steam.sh command [arguments...]' >&2
      return 2
    }

    configure_guest_environment "''${STEAM_ASAHI_GUEST_UID}"
    # Match Valve's x64 entry point when leaving a legacy Scout environment
    unset -v STEAM_RUNTIME STEAM_RUNTIME_LIBRARY_PATH

    # Steam requests a restart after updating itself or its runtime
    local status
    while true; do
      status=0
      "$@" || status=$?
      ((status == 42)) || return "''${status}"
    done
  }

  ${shell.entrypoint [ "array_expand_once" ]}
''
