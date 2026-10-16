{ ... }:

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
    exec "$@"
  }

  if [[ "''${BASH_SOURCE[0]}" == "$0" ]]; then
    shopt -s array_expand_once
    main "$@"
  fi
''
