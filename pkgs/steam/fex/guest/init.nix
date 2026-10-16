{ lib, configuration }:
let
  layout = import ../../../../lib/guest/layout.nix { inherit lib; };
  commandLinks = {
    "bin/bash" = configuration.BASH_BIN;
    "bin/lsb_release" = configuration.LSB_RELEASE;
    "bin/lspci" = configuration.LSPCI;
    "bin/pactl" = configuration.PACTL;
    "bin/sh" = configuration.SH_BIN;
    "bin/zenity" = configuration.ZENITY;
    "usr/bin/env" = configuration.ENV_BIN;
    "usr/bin/lsb_release" = configuration.LSB_RELEASE;
    "usr/bin/pactl" = configuration.PACTL;
    "usr/bin/zenity" = configuration.ZENITY;
  };
  fusermountWrappers = {
    "fusermount" = configuration.FUSERMOUNT;
    "fusermount3" = configuration.FUSERMOUNT3;
  };
  hostDirectories = [
    "bin"
    "usr"
  ];
in
''
  # shellcheck shell=bash
  #
  # Builds the temporary FHS layout required by Steam and Pressure Vessel

  install_fhs_commands() {
    ${layout.links ''"$FHS_ROOT"'' commandLinks}
    ln --symbolic --force --no-target-directory -- "$FHS_ROOT"/bin/lspci "$FHS_ROOT"/usr/bin/lspci
  }

  install_etc_overlay() {
    populate_etc_overlay || return
    mount "''${MOUNT_BASE_ARGS[@]}" --bind "''${FHS_ROOT}/etc" /etc
  }

  install_fusermount_wrappers() {
    local wrappers_root=''${WRAPPERS_BIN_DIRECTORY%/*}

    mount \
      "''${MOUNT_BASE_ARGS[@]}" \
      --mkdir=0755 \
      --types=tmpfs \
      --options=nodev,noatime,nosymfollow,exec,suid,mode=0755,size=4M,nr_inodes=64 \
      tmpfs \
      "''${wrappers_root}" || return
    mkdir --parents -- "''${WRAPPERS_BIN_DIRECTORY}" || return
    ${lib.concatMapAttrsStringSep "\n" (name: target: ''
      install --group=root --mode=u=srx,g=x,o=x --owner=root \
        --no-target-directory -- ${lib.escapeShellArg target} \
        "$WRAPPERS_BIN_DIRECTORY"/${lib.escapeShellArg name} || return
    '') fusermountWrappers}
  }

  main() {
    require_muvm_guest || return

    # /usr is read-only in the guest. Construct a writable FHS tree in tmpfs,
    # then bind it over the inherited host directories
    ${layout.directories ''"$FHS_ROOT"'' [
      "bin"
      "usr"
      "usr/bin"
      "usr/lib"
      "usr/lib64"
    ]}
    ${layout.copyDirectories ''"$FHS_ROOT"'' hostDirectories}

    install_fhs_commands || return

    # Pressure Vessel generates locales from glibc's charmaps when needed
    mkdir --parents -- "''${FHS_ROOT}/usr/share" || return
    rm --force --recursive --one-file-system --preserve-root=all -- \
      "''${FHS_ROOT}/usr/share/i18n" || return
    ln --symbolic --no-target-directory -- \
      ${lib.escapeShellArg configuration.GLIBC_I18N} \
      "''${FHS_ROOT}/usr/share/i18n" || return
    install_host_locale_data || return

    # Steam creates overlay and Fossilize layer metadata in users' XDG trees
    install_vulkan_metadata || return
    install_extra_vulkan_metadata \
      /home/*/.local/share/vulkan/implicit_layer.d/steam*.json || return
    ${layout.bindDirectories ''"$FHS_ROOT"'' hostDirectories}
    install_etc_overlay || return
    install_fusermount_wrappers
  }

  if [[ "''${BASH_SOURCE[0]}" == "$0" ]]; then
    shopt -s array_expand_once inherit_errexit nullglob
    main "$@"
  fi
''
