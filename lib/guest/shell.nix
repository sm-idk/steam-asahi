{ lib }:
{
  # Match writeShellApplication's escaping and explicit export declarations
  exports = lib.concatMapAttrsStringSep "\n" (
    name: value: ''
      ${lib.toShellVar name value}
      export ${name}
    ''
  );

  defaults = lib.concatMapAttrsStringSep "\n" (
    name: value: ''
      if [[ -z "''${${name}-}" ]]; then
        ${lib.toShellVar name value}
      fi
      export ${name}
    ''
  );

  # Commands receive a quoted staging path beside the destination and must
  # return nonzero on failure; the shared runtime helpers handle the rename
  atomicUpdate = path: commands: ''
    local temporary_path

    create_managed_temporary_path temporary_path ${path} || return
    if ! ${lib.concatStringsSep " \\\n      || ! " (commands ''"$temporary_path"'')}; then
      rm --force -- "$temporary_path"
      return 1
    fi
    commit_managed_temporary_path "$temporary_path" ${path} || return
  '';

  # Keep scripts sourceable so callers can use their functions independently
  entrypoint = options: ''
    if [[ "''${BASH_SOURCE[0]}" == "$0" ]]; then
      ${lib.optionalString (options != [ ]) "shopt -s ${lib.escapeShellArgs options}"}
      main "$@"
    fi
  '';
}
