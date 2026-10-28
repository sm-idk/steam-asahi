{
  lib,
  git,
  nix,
  steam-arm64-client,
  steam-x86_64-client,
  writeShellApplication,
}:

writeShellApplication {
  name = "update-steam-clients";
  inheritPath = false;
  runtimeInputs = [
    git
    nix
  ];
  text = ''
    ${lib.escapeShellArgs steam-arm64-client.updateScript}
    ${lib.escapeShellArgs steam-x86_64-client.updateScript}
  '';
}
