{
  module,
  nixpkgs,
  pkgs,
}:

let
  inherit (nixpkgs.lib)
    any
    elem
    filter
    hasInfix
    hasSuffix
    head
    map
    optionalString
    take
    ;

  moduleEvaluation = nixpkgs.lib.evalModules {
    class = "nixos";
    modules = [ module ];
  };

  moduleGraph = builtins.head moduleEvaluation.graph;
  implementationGraph = builtins.head moduleGraph.imports;

  rejectsWrongClass = builtins.tryEval (
    builtins.deepSeq
      (nixpkgs.lib.evalModules {
        class = "darwin";
        modules = [ module ];
      }).graph
      true
  );

  rejectsImplementationWrongClass = builtins.tryEval (
    builtins.deepSeq
      (nixpkgs.lib.evalModules {
        class = "darwin";
        modules = [ ./steam-asahi.nix ];
      }).graph
      true
  );

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
    programs.steam-asahi.users = [ "alice" ];
    services.pipewire = {
      enable = true;
      pulse.enable = true;
    };
  };

  arm64 = mkAarch64System {
    programs.steam-asahi.backend = "arm64";
    services.pipewire = {
      enable = true;
      pulse.enable = true;
    };
  };

  steamArm64Client = defaults.pkgs.steam-arm64-client;
  steamArm64ClientPurlSpec = "valve/${steamArm64Client.pname}@${steamArm64Client.version}";
  steamArm64ClientPurl = "pkg:generic/${steamArm64ClientPurlSpec}";

  probePackage = defaults.pkgs.callPackage (
    {
      extraEnv ? { },
      memoryMiB ? null,
      publishPorts ? [ ],
      vramMiB ? null,
    }:
    defaults.pkgs.runCommand "steam-asahi-module-probe" {
      passthru = {
        inherit
          extraEnv
          memoryMiB
          publishPorts
          vramMiB
          ;
      };
    } "touch $out"
  ) { };

  preconfiguredProbePackage = probePackage.override {
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
assert module._class == "nixos";
assert hasSuffix "flake.nix#nixosModules.default" module._file;
assert module.key == module._file;
assert moduleGraph.file == module._file;
assert moduleGraph.key == module.key;
assert hasSuffix "/modules/steam-asahi.nix" implementationGraph.file;
assert implementationGraph.key == implementationGraph.file;
assert !rejectsWrongClass.success;
assert !rejectsImplementationWrongClass.success;
assert builtins.length deduplicated.config.nixpkgs.overlays == 1;
assert hasSuffix "/modules/steam-asahi.nix" (
  builtins.head defaults.options.programs.steam-asahi.enable.declarations
);
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
    STEAM_RUNTIME = "1";
  };
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
assert defaults.pkgs.steam-asahi.pname == "steam-asahi";
assert defaults.pkgs.steam-asahi.version == defaults.pkgs.steam-unwrapped.version;
assert defaults.pkgs.steam-asahi.meta.homepage == "https://github.com/sm-idk/steam-asahi";
assert defaults.pkgs.steam-asahi.meta.license == defaults.pkgs.lib.licenses.unfreeRedistributable;
assert defaults.pkgs.steam-asahi.meta.mainProgram == "steam-asahi";
assert defaults.pkgs.steam-asahi.backend == "x86-fex";
assert defaults.pkgs.steam-asahi-arm64.pname == "steam-asahi-arm64";
assert defaults.pkgs.steam-asahi-arm64.version == steamArm64Client.version;
assert defaults.pkgs.steam-asahi-arm64.meta.homepage == "https://github.com/sm-idk/steam-asahi";
assert
  defaults.pkgs.steam-asahi-arm64.meta.license == defaults.pkgs.lib.licenses.unfreeRedistributable;
assert defaults.pkgs.steam-asahi-arm64.meta.mainProgram == "steam-asahi";
assert defaults.pkgs.steam-asahi-arm64.backend == "arm64";
assert steamArm64Client.meta.identifiers.purlParts.type == "generic";
assert steamArm64Client.meta.identifiers.purlParts.spec == steamArm64ClientPurlSpec;
assert steamArm64Client.meta.identifiers.v1.purl == steamArm64ClientPurl;
assert builtins.baseNameOf (toString steamArm64Client.updateScript) == "update.py";
assert defaults.config.users.groups.kvm.members == [ "alice" ];
assert defaults.config.hardware.graphics.enable;
assert defaults.config.hardware.steam-hardware.enable;
assert builtins.length muvmWirePlumberConfigs == 1;
assert noAudio.config.services.pipewire.wireplumber.configPackages == [ ];
assert
  take 2 defaults.config.environment.systemPackages == [
    defaults.config.programs.steam-asahi.package
    defaults.pkgs.muvm
  ];
assert !(elem defaults.pkgs.fex defaults.config.environment.systemPackages);
assert conflicts.config.programs.steam.enable;
assert conflicts.config.hardware.graphics.enable32Bit;
assert builtins.length (steamAsahiFailures conflicts) == 2;
assert builtins.length (steamAsahiFailures wrongPlatform) == 1;
assert any (
  warning: hasInfix "expects a PulseAudio-compatible socket" warning
) noAudio.config.warnings;
pkgs.runCommand "steam-asahi-nixos-module-test" { } ''
  ${optionalString (pkgs.stdenv.hostPlatform.system == "aarch64-linux") ''
    test -f ${muvmWirePlumberConfig}/share/wireplumber/wireplumber.conf.d/50-muvm-access.conf
    test -f ${muvmWirePlumberConfig}/share/wireplumber/scripts/client/access-muvm.lua
  ''}
  mkdir "$out"
  cp ${optionsDoc.optionsCommonMark} "$out/options.md"
''
