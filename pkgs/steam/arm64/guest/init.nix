{ lib, configuration }:
let
  layout = import ../../../../lib/guest/layout.nix { inherit lib; };
  commandLinks = {
    "bin/bash" = configuration.BASH_BIN;
    "bin/getopt" = configuration.GETOPT;
    "bin/lsb_release" = configuration.LSB_RELEASE;
    "bin/lsof" = configuration.LSOF;
    "bin/lspci" = configuration.LSPCI;
    "bin/sh" = configuration.SH_BIN;
    "bin/taskset" = configuration.TASKSET;
    "bin/zenity" = configuration.ZENITY;
    "usr/bin/getopt" = configuration.GETOPT;
    "usr/bin/lsb_release" = configuration.LSB_RELEASE;
    "usr/bin/lsof" = configuration.LSOF;
    "usr/bin/taskset" = configuration.TASKSET;
    "usr/bin/xdg-open" = configuration.XDG_OPEN;
    "usr/bin/xdg-user-dir" = configuration.XDG_USER_DIR;
    "usr/bin/zenity" = configuration.ZENITY;
  };
  libraryDirectories = [
    "/lib"
    "/lib/aarch64-linux-gnu"
    "/usr/lib"
    "/usr/lib64"
    "/usr/lib/aarch64-linux-gnu"
  ];
  bindDirectories = [
    "bin"
    "lib"
    "usr"
  ];
  copyDirectories = [
    "bin"
    "usr"
  ];
  sharedLinks = {
    "X11/locale" = configuration.X11_LOCALE;
    "i18n" = configuration.GLIBC_I18N;
    "zoneinfo" = configuration.TZDATA_ZONEINFO;
  };
in
''
  # shellcheck shell=bash
  #
  # Builds the temporary FHS layout required by Valve's ARM64 Steam binaries

  link_commands() {
    local command_directory
    local destination=$1
    local -a command_paths

    for command_directory in ${
      lib.escapeShellArgs (
        [
          configuration.COREUTILS_BIN
          configuration.GLIBC_BIN
        ]
        ++ configuration.EXTRA_COMMAND_DIRS
      )
    }; do
      command_paths=("''${command_directory}"/*)
      if ((''${#command_paths[@]} == 0)); then
        printf 'ERROR: no commands found under %s\n' \
          "''${command_directory}" >&2
        return 1
      fi
      ln \
        --symbolic \
        --force \
        --no-dereference \
        --target-directory="''${destination}" \
        -- \
        "''${command_paths[@]}" || return
    done
  }

  install_fhs_commands() {
    local root=$1

    link_commands "''${root}/bin" || return
    link_commands "''${root}/usr/bin" || return
    ${layout.links ''"$root"'' commandLinks}
    ln --symbolic --force --no-target-directory -- "$root"/bin/lspci "$root"/usr/bin/lspci
  }

  # Populates the guest FHS with the dynamic linker and native Nix libraries
  install_native_libraries() {
    local relative_path
    local -a library_paths=(${lib.escapeShellArg configuration.NATIVE_RUNTIME}/lib/*)

    # Copy ldconfig like nixpkgs does because Pressure Vessel remaps /usr in
    # nested containers and can loop on a store symlink
    if [[ -L "''${FHS_ROOT}/usr/sbin" ]]; then
      rm --force -- "''${FHS_ROOT}/usr/sbin" || return
    fi
    mkdir --parents -- "''${FHS_ROOT}/sbin" "''${FHS_ROOT}/usr/sbin" || return
    for relative_path in sbin/ldconfig usr/sbin/ldconfig; do
      install --mode=0755 --no-target-directory -- \
        ${lib.escapeShellArg configuration.LDCONFIG} "''${FHS_ROOT}/''${relative_path}" || return
    done

    # Steam's own runtime takes precedence later. This fallback provides the
    # native dynamic linker and libraries needed by initial client probes
    ln --symbolic --force --no-target-directory -- \
      ${lib.escapeShellArg configuration.LD_LINUX} \
      "''${FHS_ROOT}/lib/ld-linux-aarch64.so.1" || return
    if ((''${#library_paths[@]} == 0)); then
      printf 'ERROR: no native libraries found under %s/lib\n' \
        ${lib.escapeShellArg configuration.NATIVE_RUNTIME} >&2
      return 1
    fi
    ${lib.concatMapStringsSep "\n" (directory: ''
      ln \
        --symbolic \
        --force \
        --no-dereference \
        --target-directory="$FHS_ROOT"${lib.escapeShellArg directory} \
        -- \
        "''${library_paths[@]}" || return
    '') libraryDirectories}
  }

  # Exposes immutable locale, timezone, and X11 data in the temporary FHS
  install_shared_data() {
    local share_directory="''${FHS_ROOT}/usr/share"

    mkdir --parents -- "''${share_directory}/X11" || return
    ${lib.concatMapAttrsStringSep "\n" (path: target: ''
      rm --force --recursive --one-file-system --preserve-root=all -- \
        "''${share_directory:?}"/${lib.escapeShellArg path} || return
      ln --symbolic --no-target-directory -- ${lib.escapeShellArg target} \
        "$share_directory"/${lib.escapeShellArg path} || return
    '') sharedLinks}
  }

  # Writes passwd entries with the requested home for the matching guest UID
  # Globals: STEAM_ASAHI_GUEST_HOME, STEAM_ASAHI_GUEST_UID
  # Arguments: source passwd file; outputs updated entries to stdout
  write_guest_passwd() {
    local account_name
    local entry_uid
    local gecos
    local gid
    local home
    local login_shell
    local password

    while IFS=: read -r \
      account_name password entry_uid gid gecos home login_shell \
      || [[ -n "''${account_name}" ]]; do
      if [[ "''${entry_uid}" == "''${STEAM_ASAHI_GUEST_UID}" ]]; then
        home=''${STEAM_ASAHI_GUEST_HOME}
      fi
      printf '%s:%s:%s:%s:%s:%s:%s\n' \
        "''${account_name}" "''${password}" "''${entry_uid}" "''${gid}" \
        "''${gecos}" "''${home}" "''${login_shell}" || return
    done <"$1"
  }

  # Copies host identity files into a writable /etc and updates the guest
  # user's home directory when the launcher requests isolated state
  install_etc_overlay() {
    local passwd_path="''${FHS_ROOT}/etc/passwd"
    local temporary_path

    populate_etc_overlay || return

    # HOME alone is insufficient for isolated Steam state because parts of the
    # client consult getpwuid(). Mirror the requested guest HOME in passwd
    if [[ -n "''${STEAM_ASAHI_GUEST_HOME:-}" &&
      -n "''${STEAM_ASAHI_GUEST_UID:-}" ]]; then
      [[ "''${STEAM_ASAHI_GUEST_UID}" =~ ^[0-9]+$ ]] \
        || die 'guest UID must be numeric'
      [[ "''${STEAM_ASAHI_GUEST_HOME}" == /* &&
        "''${STEAM_ASAHI_GUEST_HOME}" != *:* &&
        "''${STEAM_ASAHI_GUEST_HOME}" != *$'\n'* &&
        "''${STEAM_ASAHI_GUEST_HOME}" != *$'\r'* ]] \
        || die 'guest HOME must be an absolute path without passwd delimiters'
      create_managed_temporary_path temporary_path "''${passwd_path}" || return
      if ! write_guest_passwd "''${passwd_path}" >"''${temporary_path}" \
        || ! chmod --reference="''${passwd_path}" -- "''${temporary_path}"; then
        rm --force -- "''${temporary_path}"
        return 1
      fi
      commit_managed_temporary_path "''${temporary_path}" "''${passwd_path}" \
        || return
    fi

    printf '%s\n' ${lib.escapeShellArgs (libraryDirectories ++ [ "/run/opengl-driver/lib" ])} \
      >"$FHS_ROOT/etc/ld.so.conf" || return
    mount "''${MOUNT_BASE_ARGS[@]}" --bind "''${FHS_ROOT}/etc" /etc
  }

  # Builds the writable /var tree and generates the library cache used by
  # libcapsule when it imports the host graphics stack
  install_var_overlay() {
    # libcapsule consults Debian's auxiliary cache location while importing host
    # graphics libraries. NixOS has no cache, so construct one in the guest FHS
    mkdir --parents -- \
      "''${FHS_ROOT}/var/cache/ldconfig" \
      "''${FHS_ROOT}/var/lib" \
      "''${FHS_ROOT}/var/log" \
      "''${FHS_ROOT}/var/tmp" || return
    chmod 1777 -- "''${FHS_ROOT}/var/tmp" || return
    ln --symbolic --force --no-target-directory -- \
      /run \
      "''${FHS_ROOT}/var/run" || return
    # The unprivileged guest cannot add a mountpoint to inherited /var, but can
    # bind over the existing /var mountpoint
    mount "''${MOUNT_BASE_ARGS[@]}" --bind "''${FHS_ROOT}/var" /var || return
    ${lib.escapeShellArg configuration.LDCONFIG} -X -f /etc/ld.so.conf -C /var/cache/ldconfig/ld.so.cache \
      || return
    rm --force -- /etc/ld.so.cache || return
    ln --symbolic --no-target-directory -- \
      /var/cache/ldconfig/ld.so.cache \
      /etc/ld.so.cache
  }

  main() {
    require_muvm_guest || return

    # None of the installation globs depend on lexical order
    local -r GLOBSORT=nosort

    # Valve's binaries request /lib/ld-linux-aarch64.so.1 and assume a
    # conventional distro filesystem. These guest-only tmpfs mounts never modify
    # host paths
    ${layout.directories ''"$FHS_ROOT"'' [
      "bin"
      "lib/aarch64-linux-gnu"
      "usr/bin"
    ]}
    ${layout.copyDirectories ''"$FHS_ROOT"'' copyDirectories}
    ${layout.directories ''"$FHS_ROOT"'' (
      [ "usr/bin" ] ++ map (lib.removePrefix "/") libraryDirectories
    )}
    install_fhs_commands "''${FHS_ROOT}" || return
    install_native_libraries || return
    install_shared_data || return
    install_host_locale_data || return
    install_vulkan_metadata || return

    ${layout.bindDirectories ''"$FHS_ROOT"'' bindDirectories}
    # muvm mounts /run noexec; allow the copied ldconfig binary to execute
    mount "''${MOUNT_BASE_ARGS[@]}" --options=exec --bind \
      "''${FHS_ROOT}/usr/sbin" /usr/sbin || return
    # NixOS may have no /sbin, and muvm cannot create it in the shared host root
    # Pressure Vessel also searches /usr/sbin, so /sbin is optional in the guest
    if [[ -d /sbin ]]; then
      mount "''${MOUNT_BASE_ARGS[@]}" --options=exec --bind \
        "''${FHS_ROOT}/sbin" /sbin || return
    fi
    install_etc_overlay || return
    install_var_overlay
  }

  if [[ "''${BASH_SOURCE[0]}" == "$0" ]]; then
    shopt -s array_expand_once inherit_errexit nullglob
    main "$@"
  fi
''
