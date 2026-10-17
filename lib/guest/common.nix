{ lib }:
let
  shell = import ./shell.nix { inherit lib; };
  constants = {
    ARM64_CLIENT_DIRECTORY_NAME = "steamrtarm64";
    FHS_ROOT = "/run/fhs";
    LOCALE_ARCHIVE_PATH = "/run/current-system/sw/lib/locale/locale-archive";
    OPENGL_DRIVER_ROOT = "/run/opengl-driver";
    OPENGL_VULKAN_SHARE = "/run/opengl-driver/share/vulkan";
    PCI_DEVICES_DIRECTORY = "/sys/bus/pci/devices";
    MUVM_HOST_DIRECTORY = "/run/muvm-host";
    VULKAN_OVERRIDES = "/run/fhs/usr/lib/pressure-vessel/overrides/share/vulkan";
    VULKAN_SHARE = "/run/fhs/usr/share/vulkan";
    WRAPPERS_BIN_DIRECTORY = "/run/wrappers/bin";
    HOST_LOCALE_VARIABLES = [
      "LANGUAGE"
      "LC_ADDRESS"
      "LC_COLLATE"
      "LC_CTYPE"
      "LC_IDENTIFICATION"
      "LC_MEASUREMENT"
      "LC_MESSAGES"
      "LC_MONETARY"
      "LC_NAME"
      "LC_NUMERIC"
      "LC_PAPER"
      "LC_TELEPHONE"
      "LC_TIME"
    ];
    GUEST_PATH_ENTRIES = [
      "/usr/local/bin"
      "/usr/bin"
      "/bin"
    ];
    GUEST_DATA_DIRECTORIES = [
      "/run/opengl-driver/share"
      "/run/current-system/sw/share"
      "/usr/local/share"
      "/usr/share"
    ];
    # Ignore host fstab policy and refuse to stack an identical guest mount
    MOUNT_BASE_ARGS = [
      "--internal-only"
      "--onlyonce"
      "--options-source=disable"
    ];
  };
  vulkanSubdirectories = [
    "icd.d"
    "explicit_layer.d"
    "implicit_layer.d"
  ];
  layout = import ./layout.nix { inherit lib; };
  etcSymlinks = [
    "host.conf"
    "hosts"
    "localtime"
    "os-release"
    "resolv.conf"
    "nsswitch.conf"
    "group"
    "passwd"
    "machine-id"
  ];
  etcStubDirectories = [
    "ld.so.conf.d"
    "alternatives"
    "xdg"
    "pulse"
  ];
  etcStubFiles = [
    "ld.so.cache"
    "ld.so.conf"
    "timezone"
  ];
  driverEnvironment = import ./environment.nix { inherit lib; };
in
''
  # shellcheck shell=bash
  #
  # Shared runtime policy for the Steam Asahi guest setup scripts

  # FEX uses the rootfs's Bash, independently of the version provided by Nix
  if ((BASH_VERSINFO[0] < 5)) \
    || ((BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 3)); then
    printf 'ERROR: Steam Asahi requires Bash >= 5.3; found %s\n' \
      "''${BASH_VERSION}" >&2
    exit 1
  fi

  ${lib.toShellVars constants}
  # Each entry point uses a subset of the shared constants
  # shellcheck disable=SC2034
  readonly ${lib.concatStringsSep " " (builtins.attrNames constants)}

  # Writes an error to stderr and exits with status 1
  # Arguments: words of the error message
  die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
  }

  # Requires muvm's host filesystem mount before any guest mount changes
  # Globals: MUVM_HOST_DIRECTORY; requires util-linux mountpoint
  require_muvm_guest() {
    mountpoint --quiet -- "''${MUVM_HOST_DIRECTORY}" \
      || die 'guest initialization requires the muvm host filesystem mount'
  }

  # Clears inherited locale categories and exports the guest's UTF-8 locale
  # Globals: HOST_LOCALE_VARIABLES; writes LANG and LC_ALL
  configure_guest_locale() {
    unset -v "''${HOST_LOCALE_VARIABLES[@]}"
    ${shell.exports {
      LC_ALL = "C.UTF-8";
      LANG = "C.UTF-8";
    }}
  }

  # Exports shared graphics, audio, and data paths for the guest client
  # Arguments: numeric host user ID, optional additional guest PATH entries
  # Globals: guest path and data arrays
  configure_guest_environment() {
    local guest_uid=$1

    shift
    [[ "''${guest_uid}" =~ ^[0-9]+$ ]] || die 'guest UID must be numeric'
    prepend_colon_path PATH "''${GUEST_PATH_ENTRIES[@]}" "$@"
    export PULSE_SERVER="unix:/run/user/''${guest_uid}/pulse/native"
    prepend_colon_path XDG_DATA_DIRS "''${GUEST_DATA_DIRECTORIES[@]}"
    ${driverEnvironment.common}
    configure_guest_locale
    # Pressure Vessel imports /usr/lib/locale but does not preserve the host's
    # /run/current-system path inside the nested game container
    ${shell.exports {
      LOCALE_ARCHIVE = "/usr/lib/locale/locale-archive";
      SDL_AUDIODRIVER = "pulseaudio";
      TZDIR = "/usr/share/zoneinfo";
    }}
    unset -v GIO_EXTRA_MODULES
  }

  # Prepends entries to an exported colon-separated path without empty entries
  # Arguments: variable name, nonempty entries to prepend
  prepend_colon_path() {
    local variable_name=$1
    local existing_value=''${!variable_name-}
    local entry
    local joined_value=
    local -a existing_entries=()

    shift
    while [[ "''${existing_value}" == *:* ]]; do
      existing_entries+=("''${existing_value%%:*}")
      existing_value=''${existing_value#*:}
    done
    existing_entries+=("''${existing_value}")
    for entry in "$@" "''${existing_entries[@]}"; do
      [[ -n "''${entry}" ]] || continue
      joined_value+="''${joined_value:+:}''${entry}"
    done
    printf -v "''${variable_name}" '%s' "''${joined_value}"
    export "''${variable_name?}"
  }

  # Runs lspci with the original arguments only when PCI devices exist
  # Globals: PCI_DEVICES_DIRECTORY; requires nullglob
  run_lspci_if_devices_exist() {
    local -r GLOBSORT=nosort
    local -a device_paths

    if [[ -d "''${PCI_DEVICES_DIRECTORY}" ]]; then
      device_paths=("''${PCI_DEVICES_DIRECTORY}"/*)
      ((''${#device_paths[@]} == 0)) || exec lspci "$@"
    fi
  }

  # Creates a private staging file on the same filesystem as its destination
  # Arguments: result variable name, destination path
  # Outputs: sets the result variable; returns nonzero if mktemp fails
  create_managed_temporary_path() {
    local result_name=$1
    local destination=$2
    local destination_directory=''${destination%/*}
    local destination_name=''${destination##*/}
    local generated_path

    [[ "''${destination_directory}" != "''${destination}" ]] \
      || destination_directory=.
    generated_path=$(mktemp \
      --tmpdir="''${destination_directory}" \
      ".''${destination_name}.XXXXXX") || return
    printf -v "''${result_name}" '%s' "''${generated_path}"
  }

  # Replaces a destination by rename, removing the staging file on failure
  # Arguments: temporary path next to the destination, destination path
  # Returns: nonzero if the rename fails
  commit_managed_temporary_path() {
    local temporary_path=$1
    local destination=$2

    if ! mv --force --no-copy --no-target-directory -- \
      "''${temporary_path}" "''${destination}"; then
      rm --force -- "''${temporary_path}"
      return 1
    fi
  }

  # Copies a host symlink target into the writable guest /etc overlay
  # Arguments: name below FHS_ROOT/etc
  materialize_etc_symlink() {
    local file_name=$1
    local path="''${FHS_ROOT}/etc/''${file_name}"
    local target

    [[ -L "''${path}" ]] || return 0
    target=$(readlink --canonicalize -- "''${path}" 2>/dev/null) || return 0
    if [[ -f "''${target}" ]]; then
      ${shell.atomicUpdate ''"$path"'' (temporary: [
        ''cp --preserve=mode --no-target-directory -- "$target" ${temporary}''
      ])}
    elif [[ -d "''${target}" ]]; then
      rm --force -- "''${path}" || return
      mkdir --parents -- "''${path}" || return
      cp --archive --one-file-system -- "''${target}/." "''${path}/"
    fi
  }

  # Copies host /etc and prepares the declared writable stubs
  # Globals: FHS_ROOT
  populate_etc_overlay() {
    mkdir --parents -- "''${FHS_ROOT}/etc" || return
    cp --archive --one-file-system -- /etc/. "''${FHS_ROOT}/etc/" \
      2>/dev/null || true
    ${lib.concatMapStringsSep "\n" (name: ''
      materialize_etc_symlink ${lib.escapeShellArg name} || return
    '') etcSymlinks}
    ${layout.directories ''"$FHS_ROOT/etc"'' etcStubDirectories}
    ${lib.concatMapStringsSep "\n" (name: ''
      rm --force -- "$FHS_ROOT/etc"/${lib.escapeShellArg name} || return
    '') etcStubFiles}
    ${layout.files ''"$FHS_ROOT/etc"'' {
      mode = "0644";
      targets = lib.genAttrs etcStubFiles (_: "/dev/null");
    }}
  }

  # Mirrors graphics manifests into the native loader and Pressure Vessel paths
  # Optional user manifests are installed separately by the FEX backend
  # Globals: Vulkan source/destination constants; requires nullglob
  install_vulkan_metadata() {
    local -a manifest_paths

    mkdir --parents -- "''${VULKAN_SHARE}" "''${VULKAN_OVERRIDES}" || return
    ${lib.concatMapStringsSep "\n" (subdirectory: ''
      if [[ -e "$OPENGL_VULKAN_SHARE"/${lib.escapeShellArg subdirectory} ]]; then
        ${layout.replaceLinks ''"$VULKAN_SHARE"'' {
          ${subdirectory} = "${constants.OPENGL_VULKAN_SHARE}/${subdirectory}";
        }}
        ${layout.directories ''"$VULKAN_OVERRIDES"'' [ subdirectory ]}
        manifest_paths=("$OPENGL_VULKAN_SHARE"/${lib.escapeShellArg subdirectory}/*.json)
        ((''${#manifest_paths[@]} == 0)) || ln \
          --symbolic \
          --force \
          --no-dereference \
          --target-directory="$VULKAN_OVERRIDES"/${lib.escapeShellArg subdirectory} \
          -- \
          "''${manifest_paths[@]}" || return
      fi
    '') vulkanSubdirectories}
  }

  # Copies user manifests into Pressure Vessel's implicit-layer directory
  # Arguments: manifest paths; missing files are skipped
  install_extra_vulkan_metadata() {
    local extra_manifest

    (($# > 0)) || return 0
    mkdir --parents -- "''${VULKAN_OVERRIDES}/implicit_layer.d" || return
    for extra_manifest in "$@"; do
      [[ -f "''${extra_manifest}" ]] || continue
      cp \
        --force \
        --remove-destination \
        --target-directory="''${VULKAN_OVERRIDES}/implicit_layer.d" \
        -- \
        "''${extra_manifest}" \
        2>/dev/null || true
    done
  }

  # Pressure Vessel imports compiled locales from /usr/lib/locale, independently
  # of LOCALE_ARCHIVE in the client environment. Expose the same NixOS data there
  # when the host provides it; charmaps remain available for locale generation
  install_host_locale_data() {
    local locale_directory
    local destination="''${FHS_ROOT}/usr/lib/locale"

    [[ -f "''${LOCALE_ARCHIVE_PATH}" ]] || return 0
    locale_directory=$(readlink --canonicalize -- \
      "''${LOCALE_ARCHIVE_PATH%/*}") || return
    mkdir --parents -- "''${FHS_ROOT}/usr/lib" || return
    rm --force --recursive --one-file-system --preserve-root=all -- \
      "''${destination}" || return
    ln --symbolic --no-target-directory -- \
      "''${locale_directory}" "''${destination}"
  }

''
