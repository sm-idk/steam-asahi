{
  config,
  lib,
  module,
  pretendAarch64 ? false,
  ...
}:

let
  nodePkgs = config.node.pkgs;

  probePackage = nodePkgs.callPackage (
    {
      extraEnv ? { },
      memoryMiB ? null,
      publishPorts ? [ ],
      vramMiB ? null,
    }:
    nodePkgs.writeShellApplication {
      name = "steam-asahi-module-probe";
      text = ''
        printf '%s\n' ${
          lib.strings.escapeShellArg (
            builtins.toJSON {
              inherit
                extraEnv
                memoryMiB
                publishPorts
                vramMiB
                ;
            }
          )
        }
      '';
    }
  ) { };

  wirePlumberConfigs = lib.lists.filter (
    package: lib.strings.hasInfix "muvm-wireplumber-config" package.name
  ) config.nodes.machine.services.pipewire.wireplumber.configPackages;

  wirePlumberConfig =
    assert builtins.length wirePlumberConfigs == 1;
    builtins.head wirePlumberConfigs;

  moduleUnderTest =
    if pretendAarch64 then
      {
        config,
        lib,
        pkgs,
        ...
      }:
      import module {
        inherit config lib;
        pkgs = pkgs // {
          stdenv = pkgs.stdenv // {
            hostPlatform = pkgs.stdenv.hostPlatform // {
              system = "aarch64-linux";
            };
          };
        };
      }
    else
      module;
in
{
  name = "steam-asahi-module";

  nodes.machine = {
    imports = [ moduleUnderTest ];

    programs.steam-asahi = {
      enable = true;
      extraEnv = {
        FEX_MULTIBLOCK = null;
        TEST_FROM_MODULE = "value with spaces";
      };
      memoryMiB = 1536;
      package = probePackage;
      vramMiB = 768;
      remotePlay.openFirewall = true;
      dedicatedServer.openFirewall = true;
      localNetworkGameTransfers.openFirewall = true;
    };

    services.pipewire = {
      enable = true;
      pulse.enable = true;
    };

    users.users.alice = {
      isNormalUser = true;
      extraGroups = [ "kvm" ];
    };
    virtualisation.memorySize = 768;
  };

  testScript = ''
    import json

    machine.start()
    machine.wait_for_unit("multi-user.target")

    machine.succeed("id -nG alice | tr ' ' '\\n' | grep -Fx kvm")
    machine.succeed("muvm --version | grep -Fx 'muvm test double'")

    probe = json.loads(machine.succeed("steam-asahi-module-probe"))
    assert probe == {
        "extraEnv": {
            "GTK_IM_MODULE": "xim",
            "PRESSURE_VESSEL_IMPORT_VULKAN_LAYERS": "0",
            "STEAMOS": "1",
            "STEAM_RUNTIME": "1",
            "TEST_FROM_MODULE": "value with spaces",
        },
        "memoryMiB": 1536,
        "publishPorts": [
            "27036/udp",
            "27036/tcp",
            "27037/tcp",
            "10400/udp",
            "10401/udp",
            "27031-27035/udp",
            "27015/tcp",
            "27015/udp",
            "27040/tcp",
        ],
        "vramMiB": 768,
    }

    machine.succeed(
        "test -f "
        + "${wirePlumberConfig}/share/wireplumber/"
        + "wireplumber.conf.d/50-muvm-access.conf"
    )
    machine.succeed(
        "test -f "
        + "${wirePlumberConfig}/share/wireplumber/"
        + "scripts/client/access-muvm.lua"
    )
  '';
}
