{
  lib,
  upstream,
  fetchFromGitLab,
  rustPlatform,
  nix-update-script,
  ffmpeg,
  ffmpeg_8,
  python3,
  rustfmt,
  wayland-protocols,
}:

let
  waypipeOverrideVersion = "0.11.2";
  isCurrent = lib.versionAtLeast upstream.version waypipeOverrideVersion;
  overridden = upstream.overrideAttrs (
    finalAttrs: old: {
      version = waypipeOverrideVersion;
      src = fetchFromGitLab {
        domain = "gitlab.freedesktop.org";
        owner = "mstoeckl";
        repo = "waypipe";
        tag = "v${finalAttrs.version}";
        hash = "sha256-n/Of0jz4tm0q+uSV4i2LbZNqzF13ToOmeeywFtvW7wM=";
      };
      cargoDeps = rustPlatform.fetchCargoVendor {
        inherit (finalAttrs) pname version src;
        hash = "sha256-38C9H1NL14xuacvjlUR45EYomdUznKC5BXg1Y5RkSH4=";
      };
      passthru = (old.passthru or { }) // {
        updateScript = nix-update-script {
          attrPath = "waypipe";
          extraArgs = [
            "--flake"
            "--system=aarch64-linux"
            "--override-filename=pkgs/waypipe/override.nix"
          ];
        };
      };
    }
  );
in
# These protocols contain ordinary objects, strings, and integers, so Waypipe's
# generic object tracking can forward them without another resource transport
(lib.warnIf isCurrent ''
  Waypipe >= ${waypipeOverrideVersion} is now in nixpkgs; its version pin can be removed while retaining the additional protocols.
'' (if isCurrent then upstream else overridden)).overrideAttrs
  (old: {
    buildInputs = map (input: if input == ffmpeg_8 then ffmpeg else input) old.buildInputs;
    runtimeDependencies = map (
      input: if input == ffmpeg_8.lib then ffmpeg.lib else input
    ) old.runtimeDependencies;
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
      python3
      rustfmt
    ];
    postPatch = (old.postPatch or "") + ''
      cp ${wayland-protocols}/share/wayland-protocols/unstable/idle-inhibit/idle-inhibit-unstable-v1.xml protocols/
      cp ${wayland-protocols}/share/wayland-protocols/unstable/xdg-foreign/xdg-foreign-unstable-v1.xml protocols/
      cp ${wayland-protocols}/share/wayland-protocols/unstable/xdg-foreign/xdg-foreign-unstable-v2.xml protocols/
      cp ${wayland-protocols}/share/wayland-protocols/staging/xdg-activation/xdg-activation-v1.xml protocols/
      python3 protogen.py
    '';
  })
