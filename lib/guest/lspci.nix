{ ... }:

''
  # shellcheck shell=bash
  #
  # Hides pciutils errors on Apple Silicon systems that have no PCI devices

  main() {
    run_lspci_if_devices_exist "$@"
  }

  if [[ "''${BASH_SOURCE[0]}" == "$0" ]]; then
    shopt -s nullglob
    main "$@"
  fi
''
