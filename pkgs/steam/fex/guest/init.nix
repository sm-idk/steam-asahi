{ lib, configuration }:
let
  shell = import ../../../../lib/guest/shell.nix { inherit lib; };
  layout = import ../../../../lib/guest/layout.nix { inherit lib; };
  commandLinks =
    (layout.commandLinks {
      lsb_release = configuration.LSB_RELEASE;
      pactl = configuration.PACTL;
      zenity = configuration.ZENITY;
    })
    // {
      "bin/bash" = configuration.BASH_BIN;
      "bin/lspci" = configuration.LSPCI;
      "bin/sh" = configuration.SH_BIN;
      "usr/bin/env" = configuration.ENV_BIN;
      "usr/bin/xdg-open" = configuration.XDG_OPEN;
      "usr/local/bin/xdg-open" = configuration.XDG_OPEN;
    }
    // lib.optionalAttrs (configuration ? GAME_LAUNCHER) {
      "usr/local/bin/steam-asahi-game" = configuration.GAME_LAUNCHER;
    }
    // lib.optionalAttrs (configuration ? DESKTOP_DIAGNOSTIC) {
      "usr/local/bin/steam-asahi-desktop-diagnostics" = configuration.DESKTOP_DIAGNOSTIC;
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
    ${layout.directories ''"$FHS_ROOT"'' [ "usr/local/bin" ]}
    ${layout.links ''"$FHS_ROOT"'' commandLinks}
    ln --symbolic --force --no-target-directory -- "$FHS_ROOT"/bin/lspci "$FHS_ROOT"/usr/bin/lspci
  }

  install_etc_overlay() {
    populate_etc_overlay || return
    ${layout.bindDirectories ''"$FHS_ROOT"'' [ "etc" ]}
  }

  install_fusermount_wrappers() {
    local wrappers_root=''${WRAPPERS_BIN_DIRECTORY%/*}

    ${layout.mount {
      source = lib.escapeShellArg "tmpfs";
      target = ''"$wrappers_root"'';
      type = "tmpfs";
      directoryMode = "0755";
      options = [
        "nodev"
        "noatime"
        "nosymfollow"
        "exec"
        "suid"
        "mode=0755"
        "size=4M"
        "nr_inodes=64"
      ];
    }}
    ${layout.directories ''"$wrappers_root"'' [ "bin" ]}
    ${layout.files ''"$WRAPPERS_BIN_DIRECTORY"'' {
      mode = "u=srx,g=x,o=x";
      owner = "root";
      group = "root";
      targets = fusermountWrappers;
    }}
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
    ${layout.directories ''"$FHS_ROOT/usr"'' [ "share" ]}
    ${layout.replaceLinks ''"$FHS_ROOT/usr/share"'' { i18n = configuration.GLIBC_I18N; }}
    install_host_locale_data || return

    # Steam creates overlay and Fossilize layer metadata in users' XDG trees
    install_vulkan_metadata || return
    install_extra_vulkan_metadata \
      /home/*/.local/share/vulkan/implicit_layer.d/steam*.json || return
    ${layout.bindDirectories ''"$FHS_ROOT"'' hostDirectories}
    install_etc_overlay || return
    install_fusermount_wrappers
  }

  ${shell.entrypoint [
    "array_expand_once"
    "inherit_errexit"
    "nullglob"
  ]}
''
