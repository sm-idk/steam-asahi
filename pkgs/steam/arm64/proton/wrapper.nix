{ lib }:
let
  runtimeLibraryPath = lib.concatStringsSep ":" [
    "/lib/aarch64-linux-gnu"
    "/usr/lib/aarch64-linux-gnu"
  ];
in
''
  # shellcheck shell=sh
  #
  # Repairs Steam's ARM64 compatibility environment before entering the runtime

  script_path=$(readlink --canonicalize -- "$0")
  tool_directory=''${script_path%/*}
  # The Nix dynamic linker remains active inside Pressure Vessel and does not
  # search the runtime's distro library directories by default. Preserve any
  # imported-library overrides ahead of these fallbacks so runtime commands such
  # as mkdir can resolve libselinux and its dependencies before Proton starts
  runtime_library_path=${lib.escapeShellArg runtimeLibraryPath}
  export LD_LIBRARY_PATH="''${LD_LIBRARY_PATH:+''${LD_LIBRARY_PATH}:}\
  ''${runtime_library_path}"
  if [ "$#" -eq 0 ]; then
    printf '%s\n' 'ERROR: missing Steam compatibility verb' >&2
    exit 2
  fi
  verb=$1
  readonly runtime_library_path script_path tool_directory verb
  shift

  # The ARM beta registers local tools as AppID 0 and can consequently derive
  # compatdata/0. Recover the target game ID from Steam's wrapper
  app_id=
  ${lib.concatMapStringsSep "\n"
    (name: ''
      if [ -z "$app_id" ]; then
        case "''${${name}:-}" in
          "" | 0 | *[!0-9]*) ;;
          *) app_id=''${${name}} ;;
        esac
      fi
    '')
    [
      "SteamAppId"
      "SteamGameId"
      "STEAM_COMPAT_APP_ID"
    ]
  }

  compat_data=''${STEAM_COMPAT_DATA_PATH:-}
  compat_data_without_trailing_slash=''${compat_data%/}
  compat_data_parent=''${compat_data_without_trailing_slash%/0}
  if [ -n "''${app_id}" ]; then
    export STEAM_COMPAT_APP_ID="''${app_id}"
    if [ "''${compat_data_without_trailing_slash##*/}" = 0 ]; then
      export STEAM_COMPAT_DATA_PATH="''${compat_data_parent}/''${app_id}"
    fi
  elif [ "''${compat_data_without_trailing_slash##*/}" = 0 ]; then
    # Steam runs tool-level graphics probes without a target game ID
    export STEAM_COMPAT_DATA_PATH="''${compat_data_parent}/steam-asahi-tool"
  fi
  if [ -n "''${STEAM_COMPAT_DATA_PATH:-}" ]; then
    mkdir --parents -- "''${STEAM_COMPAT_DATA_PATH}"
  fi

  log_path="''${tool_directory}/steam-asahi-proton.log"
  timestamp=$(date --iso-8601=seconds)
  {
    printf '\n=== %s verb=%s app=%s compatdata=%s ===\n' \
      "''${timestamp}" "''${verb}" "''${app_id:-unknown}" \
      "''${STEAM_COMPAT_DATA_PATH:-unset}"
    printf 'command:'
    if [ "$#" -gt 0 ]; then
      printf ' <%s>' "$@"
    fi
    printf '\n'
  } >>"''${log_path}"

  run_compatibility_command() {
    "''${tool_directory}/runtime/_v2-entry-point" --verb="''${verb}" -- \
      "''${tool_directory}/run-proton" "''${verb}" "$@"
  }

  # Steam consumes path-conversion results from stdout as protocol data
  case "''${verb}" in
    getcompatpath | getnativepath)
      if run_compatibility_command "$@" 2>>"''${log_path}"; then
        status=0
      else
        status=$?
      fi
      ;;
    *)
      if run_compatibility_command "$@" >>"''${log_path}" 2>&1; then
        status=0
      else
        status=$?
      fi
      ;;
  esac

  if [ "''${status}" -ne 0 ]; then
    {
      printf 'ERROR: Proton compatibility command exited with status %s.\n' \
        "''${status}"
      printf 'Last 80 lines from %s:\n' "''${log_path}"
      tail --lines=80 -- "''${log_path}" || true
    } >&2
  fi

  exit "''${status}"
''
