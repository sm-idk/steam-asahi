{
  module,
  nixpkgs,
  pkgs,
}:

let
  inherit (nixpkgs.lib.lists)
    any
    elem
    filter
    head
    map
    ;
  inherit (nixpkgs.lib.strings) hasInfix hasSuffix optionalString;

  mkSystem =
    system: extraModule:
    nixpkgs.lib.nixosSystem {
      modules = [
        module
        {
          nixpkgs.config.allowUnfree = true;
          nixpkgs.hostPlatform = system;
          programs.steam-asahi.enable = true;
          system.stateVersion = "26.11";
          users.users.alice.isNormalUser = true;
        }
        extraModule
      ];
    };

  mkAarch64System = mkSystem "aarch64-linux";

  defaults = mkAarch64System {
    services.pipewire = {
      enable = true;
      pulse.enable = true;
    };
    users.users.alice.extraGroups = [ "kvm" ];
  };

  arm64 = mkAarch64System {
    programs.steam-asahi.backend = "arm64";
    services.pipewire = {
      enable = true;
      pulse.enable = true;
    };
  };

  customHomeArm64 = mkAarch64System {
    programs.steam-asahi = {
      backend = "arm64";
      customSteamHomeDir = "custom-arm64-home";
    };
    services.pipewire = {
      enable = true;
      pulse.enable = true;
    };
  };

  probePackage = defaults.pkgs.callPackage (
    {
      cpuList ? null,
      extraEnv ? { },
      memoryMiB ? null,
      publishPorts ? [ ],
      vramMiB ? null,
    }:
    defaults.pkgs.runCommand "steam-asahi-module-probe" {
      passthru = {
        inherit
          cpuList
          extraEnv
          memoryMiB
          publishPorts
          vramMiB
          ;
      };
    } "touch $out"
  ) { };

  preconfiguredProbePackage = probePackage.override {
    cpuList = [ 7 ];
    extraEnv = {
      FEX_MULTIBLOCK = "package-value-removed-by-module";
      PACKAGE_ENVIRONMENT = "preserved";
    };
    memoryMiB = 2048;
    publishPorts = [ "9999/tcp" ];
    vramMiB = 1024;
  };

  customized = mkAarch64System {
    programs.steam-asahi = {
      cpuList = [
        0
        1
        4
        5
      ];
      extraEnv = {
        FEX_MULTIBLOCK = null;
        MANGOHUD = "1";
      };
      memoryMiB = 6144;
      package = preconfiguredProbePackage;
      vramMiB = 3072;
    };
    services.pipewire = {
      enable = true;
      pulse.enable = true;
    };
  };

  conflicts = mkAarch64System {
    hardware.graphics.enable32Bit = true;
    programs.steam.enable = true;
    services.pipewire = {
      enable = true;
      pulse.enable = true;
    };
  };

  networkingEnabled = mkAarch64System {
    programs.steam-asahi = {
      package = probePackage;
      remotePlay.openFirewall = true;
      dedicatedServer.openFirewall = true;
      localNetworkGameTransfers.openFirewall = true;
    };
    services.pipewire = {
      enable = true;
      pulse.enable = true;
    };
  };

  noAudio = mkAarch64System { };
  wrongPlatform = mkSystem "x86_64-linux" {
    services.pipewire = {
      enable = true;
      pulse.enable = true;
    };
  };

  deduplicated = nixpkgs.lib.nixosSystem {
    modules = [
      module
      module
      {
        nixpkgs.config.allowUnfree = true;
        nixpkgs.hostPlatform = "aarch64-linux";
        system.stateVersion = "26.11";
      }
    ];
  };

  steamAsahiFailures =
    system:
    filter (
      entry: !entry.assertion && hasInfix "programs.steam-asahi" entry.message
    ) system.config.assertions;

  transformDeclaration =
    declaration:
    assert hasSuffix "/modules/steam-asahi.nix" (toString declaration);
    {
      name = "modules/steam-asahi.nix";
      url = "https://github.com/sm-idk/steam-asahi/blob/main/modules/steam-asahi.nix";
    };

  optionsDoc = pkgs.nixosOptionsDoc {
    documentType = "none";
    options.programs.steam-asahi = defaults.options.programs.steam-asahi;
    transformOptions =
      option: option // { declarations = map transformDeclaration option.declarations; };
    warningsAreErrors = true;
  };

  muvmWirePlumberConfigs = filter (
    package: hasInfix "muvm-wireplumber-config" package.name
  ) defaults.config.services.pipewire.wireplumber.configPackages;
  muvmWirePlumberConfig = head muvmWirePlumberConfigs;
in
assert builtins.length deduplicated.config.nixpkgs.overlays == 1;
assert
  defaults.config.programs.steam-asahi.extraEnv == {
    FEX_MULTIBLOCK = "0";
    GTK_IM_MODULE = "xim";
    PRESSURE_VESSEL_IMPORT_VULKAN_LAYERS = "0";
    STEAMOS = "1";
    STEAM_RUNTIME = "1";
  };
assert
  arm64.config.programs.steam-asahi.extraEnv == {
    GTK_IM_MODULE = "xim";
    PRESSURE_VESSEL_IMPORT_VULKAN_LAYERS = "0";
  };
assert
  customHomeArm64.config.programs.steam-asahi.package.customSteamHomeDir == "custom-arm64-home";
assert
  customized.config.programs.steam-asahi.extraEnv == {
    FEX_MULTIBLOCK = null;
    GTK_IM_MODULE = "xim";
    MANGOHUD = "1";
    PRESSURE_VESSEL_IMPORT_VULKAN_LAYERS = "0";
    STEAMOS = "1";
    STEAM_RUNTIME = "1";
  };
assert
  customized.config.programs.steam-asahi.package.extraEnv == {
    GTK_IM_MODULE = "xim";
    MANGOHUD = "1";
    PACKAGE_ENVIRONMENT = "preserved";
    PRESSURE_VESSEL_IMPORT_VULKAN_LAYERS = "0";
    STEAMOS = "1";
    STEAM_RUNTIME = "1";
  };
assert
  customized.config.programs.steam-asahi.package.cpuList == [
    0
    1
    4
    5
  ];
assert customized.config.programs.steam-asahi.package.memoryMiB == 6144;
assert customized.config.programs.steam-asahi.package.publishPorts == [ ];
assert customized.config.programs.steam-asahi.package.vramMiB == 3072;
assert
  networkingEnabled.config.programs.steam-asahi.package.publishPorts == [
    "27036/udp"
    "27036/tcp"
    "27037/tcp"
    "10400/udp"
    "10401/udp"
    "27031-27035/udp"
    "27015/tcp"
    "27015/udp"
    "27040/tcp"
  ];
assert
  builtins.length networkingEnabled.config.networking.firewall.allowedTCPPorts == 4
  && builtins.all (port: elem port networkingEnabled.config.networking.firewall.allowedTCPPorts) [
    27015
    27036
    27037
    27040
  ];
assert
  builtins.length networkingEnabled.config.networking.firewall.allowedUDPPorts == 4
  && builtins.all (port: elem port networkingEnabled.config.networking.firewall.allowedUDPPorts) [
    10400
    10401
    27015
    27036
  ];
assert
  networkingEnabled.config.networking.firewall.allowedUDPPortRanges == [
    {
      from = 27031;
      to = 27035;
    }
  ];
assert defaults.config.users.groups.kvm.members == [ "alice" ];
assert defaults.config.hardware.graphics.enable;
assert defaults.config.hardware.steam-hardware.enable;
assert builtins.length muvmWirePlumberConfigs == 1;
assert noAudio.config.services.pipewire.wireplumber.configPackages == [ ];
assert elem defaults.config.programs.steam-asahi.package defaults.config.environment.systemPackages;
assert elem defaults.pkgs.muvm defaults.config.environment.systemPackages;
assert !(elem defaults.pkgs.fex defaults.config.environment.systemPackages);
assert builtins.length (steamAsahiFailures conflicts) == 2;
assert builtins.length (steamAsahiFailures wrongPlatform) == 1;
assert any (
  warning: hasInfix "expects a PulseAudio-compatible socket" warning
) noAudio.config.warnings;
assert any (warning: hasInfix "requires access to `/dev/kvm`" warning) arm64.config.warnings;
assert !(any (warning: hasInfix "requires access to `/dev/kvm`" warning) defaults.config.warnings);
pkgs.runCommand "steam-asahi-nixos-module-test" { } ''
  ${optionalString (pkgs.stdenv.hostPlatform.system == "aarch64-linux") ''
    test -f ${muvmWirePlumberConfig}/share/wireplumber/wireplumber.conf.d/50-muvm-access.conf
    test -f ${muvmWirePlumberConfig}/share/wireplumber/scripts/client/access-muvm.lua
  ''}
  mkdir "$out"
  cp ${optionsDoc.optionsCommonMark} "$out/options.md"
''
