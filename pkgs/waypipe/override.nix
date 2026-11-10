{
  upstream,
  ffmpeg,
  ffmpeg_8,
  python3,
  rustfmt,
  wayland-protocols,
}:

# These protocols contain ordinary objects, strings, and integers, so Waypipe's
# generic object tracking can forward them without another resource transport
upstream.overrideAttrs (old: {
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
