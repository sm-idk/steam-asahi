{ lib }:
let
  pathsUnder =
    root: paths: lib.concatMapStringsSep " " (path: "${root}/${lib.escapeShellArg path}") paths;
  links =
    root: targets:
    lib.concatMapAttrsStringSep "\n" (path: target: ''
      ln --symbolic --force --no-target-directory -- \
        ${lib.escapeShellArg target} ${root}/${lib.escapeShellArg path} || return
    '') targets;
  # Source and target are quoted shell expressions, like roots above
  mount =
    {
      source,
      target,
      bind ? false,
      options ? [ ],
      type ? null,
      directoryMode ? null,
    }:
    let
      arguments = lib.escapeShellArgs (
        lib.optional bind "--bind"
        ++ lib.optional (options != [ ]) "--options=${lib.concatStringsSep "," options}"
        ++ lib.optional (type != null) "--types=${type}"
        ++ lib.optional (directoryMode != null) "--mkdir=${directoryMode}"
      );
    in
    ''
      mount "''${MOUNT_BASE_ARGS[@]}" ${arguments} -- ${source} ${target} || return
    '';
in
{
  # Roots are shell expressions; relative paths and targets are escaped literals
  inherit pathsUnder links mount;

  # Commands shared by /bin and /usr/bin need only one declaration
  commandLinks =
    commands:
    lib.concatMapAttrs (name: target: {
      "bin/${name}" = target;
      "usr/bin/${name}" = target;
    }) commands;

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
    lib.concatMapStringsSep "\n" (
      path:
      mount {
        source = "${root}/${lib.escapeShellArg path}";
        target = lib.escapeShellArg "/${path}";
        bind = true;
      }
    ) paths;

  # Immutable data can replace inherited directories as well as symlinks
  replaceLinks =
    root: targets:
    lib.concatMapAttrsStringSep "\n" (path: target: ''
      rm --force --recursive --one-file-system --preserve-root=all -- \
        ${root}/${lib.escapeShellArg path} || return
      ${links root { ${path} = target; }}
    '') targets;

  files =
    root:
    {
      mode,
      targets,
      owner ? null,
      group ? null,
    }:
    lib.concatMapAttrsStringSep "\n" (path: source: ''
      install ${
        lib.escapeShellArgs (
          [ "--mode=${mode}" ]
          ++ lib.optional (owner != null) "--owner=${owner}"
          ++ lib.optional (group != null) "--group=${group}"
        )
      } --no-target-directory -- \
        ${lib.escapeShellArg source} ${root}/${lib.escapeShellArg path} || return
    '') targets;

  # Discover package contents at runtime; package order is fixed by Nix
  linkContents =
    destination: directories:
    lib.concatMapStringsSep "\n" (directory: ''
      command_paths=(${lib.escapeShellArg directory}/*)
      if ((''${#command_paths[@]} == 0)); then
        printf 'ERROR: no commands found under %s\n' ${lib.escapeShellArg directory} >&2
        return 1
      fi
      ln --symbolic --force --no-dereference \
        --target-directory=${destination} -- "''${command_paths[@]}" || return
    '') directories;
}
