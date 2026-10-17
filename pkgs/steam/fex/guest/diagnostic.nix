{ lib, ... }:
let
  shell = import ../../../../lib/guest/shell.nix { inherit lib; };
in

''
  # shellcheck shell=bash
  #
  # Runs a user-requested diagnostic command inside the configured FEX guest

  main() {
    (($# == 1)) || {
      printf '%s\n' 'usage: diagnostic.sh command' >&2
      return 2
    }

    prepend_colon_path PATH "''${GUEST_PATH_ENTRIES[@]}"
    configure_guest_locale

    exec "''${BASH}" -c "$1"
  }

  ${shell.entrypoint [ ]}
''
