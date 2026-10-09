{
  makeDesktopItem,
  runCommand,
  steam-unwrapped,
  symlinkJoin,
}:
{
  pname,
  version,
  launcher,
  desktopName,
  comment,
  passthru ? { },
}:
let
  # Copy icon contents so symlinks cannot retain the full Steam client
  steamIcons =
    runCommand "steam-asahi-icons-${steam-unwrapped.version}"
      {
        disallowedReferences = [ steam-unwrapped ];
      }
      ''
        mkdir -p "$out/share"
        cp --recursive --dereference -- ${steam-unwrapped}/share/icons "$out/share/"
      '';

  desktopItem = makeDesktopItem {
    inherit desktopName comment;
    name = "steam-asahi";
    exec = "steam-asahi %U";
    icon = "steam";
    startupNotify = true;
    categories = [
      "Game"
      "Network"
    ];
    mimeTypes = [
      "x-scheme-handler/steam"
      "x-scheme-handler/steamlink"
    ];
  };
in
symlinkJoin {
  inherit pname version passthru;
  paths = [
    launcher
    desktopItem
    steamIcons
  ];
  inherit (launcher) meta;
}
