{ lib }:
let
  pathsUnder =
    root: paths: lib.concatMapStringsSep " " (path: "${root}/${lib.escapeShellArg path}") paths;
in
{
  # Roots are shell expressions; relative paths are always escaped as literals
  directories = root: paths: ''
    mkdir --parents -- ${pathsUnder root paths} || return
  '';

  copyDirectories =
    root: paths:
    lib.concatMapStringsSep "\n" (path: ''
      cp --archive --one-file-system -- \
        ${lib.escapeShellArg "/${path}/."} ${root}/${lib.escapeShellArg "${path}/"} \
        2>/dev/null || true
    '') paths;

  bindDirectories =
    root: paths:
    lib.concatMapStringsSep "\n" (path: ''
      mount "''${MOUNT_BASE_ARGS[@]}" --bind \
        ${root}/${lib.escapeShellArg path} ${lib.escapeShellArg "/${path}"} || return
    '') paths;

  links =
    root: targets:
    lib.concatMapAttrsStringSep "\n" (path: target: ''
      ln --symbolic --force --no-target-directory -- \
        ${lib.escapeShellArg target} ${root}/${lib.escapeShellArg path} || return
    '') targets;
}
