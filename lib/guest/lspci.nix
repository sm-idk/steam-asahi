{ lib, ... }:
let
  shell = import ./shell.nix { inherit lib; };
in

''
  # shellcheck shell=bash
  #
  # Hides pciutils errors on Apple Silicon systems that have no PCI devices

  main() {
    run_lspci_if_devices_exist "$@"
  }

  ${shell.entrypoint [ "nullglob" ]}
''
