{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3,
  muvm,
  fex,
  fuse,
  bash,
  coreutils,
  util-linux,
  writeShellScript,
  fetchurl,
}:

let
  steamBootstrap = fetchurl {
    url = "https://repo.steampowered.com/steam/archive/stable/steam_1.0.0.81.tar.gz";
    hash = "sha256-Gia5182s4J4E3Ia1EeC5kjJX9mSltsr+b+1eRtEXtPk=";
  };

  initScript = writeShellScript "steam-asahi-init" ''
    export PATH="${
      lib.makeBinPath [
        coreutils
        util-linux
      ]
    }:$PATH"

    # PulseAudio shared memory workaround (muvm guest doesn't support SHM)
    echo enable-shm=no > /run/pulse.conf

    # NixOS has no FHS paths — create them on a writable overlay over /usr.
    # /bin/bash and /usr/bin/env are needed by scripts.
    # /usr/lib and /usr/lib64 are needed by bwrap for PressureVessel/steamwebhelper.
    #
    # Strategy: /usr is read-only (host mount), so we create a writable tmpfs
    # overlay with all the FHS paths bwrap/Steam expect, then bind-mount over /usr.
    mkdir -p /run/fhs/bin /run/fhs/usr
    cp -a /bin/* /run/fhs/bin/ 2>/dev/null || true
    ln -sf ${bash}/bin/bash /run/fhs/bin/bash
    ln -sf ${bash}/bin/sh /run/fhs/bin/sh

    # Copy existing /usr contents, then add missing FHS dirs
    cp -a /usr/* /run/fhs/usr/ 2>/dev/null || true
    mkdir -p /run/fhs/usr/bin /run/fhs/usr/lib /run/fhs/usr/lib64
    ln -sf ${coreutils}/bin/env /run/fhs/usr/bin/env

    # PressureVessel Vulkan layer overrides dir (suppresses "Internal error" warnings)
    mkdir -p /run/fhs/usr/lib/pressure-vessel/overrides/share/vulkan/implicit_layer.d

    mount --bind /run/fhs/bin /bin
    mount --bind /run/fhs/usr /usr

    # Fix NixOS /etc for PressureVessel/bwrap compatibility.
    #
    # /etc is read-only inside muvm (host filesystem). Same bind-mount approach as /usr.
    # bwrap fails on NixOS symlinks (host.conf -> /etc/static/ -> /nix/store/...) when
    # it creates a new mount namespace without FEX's rootfs overlay.
    #
    # Fix: copy /etc to writable tmpfs, materialize symlinks, add stubs, bind-mount over.
    mkdir -p /run/fhs/etc
    cp -a /etc/. /run/fhs/etc/ 2>/dev/null || true

    # Materialize NixOS symlinks as real files
    for f in host.conf hosts localtime os-release resolv.conf nsswitch.conf \
             group passwd machine-id; do
      if [ -L "/run/fhs/etc/$f" ]; then
        target=$(readlink -f "/run/fhs/etc/$f" 2>/dev/null) || continue
        rm -f "/run/fhs/etc/$f"
        if [ -f "$target" ]; then
          cp "$target" "/run/fhs/etc/$f"
        elif [ -d "$target" ]; then
          mkdir -p "/run/fhs/etc/$f" && cp -a "$target/." "/run/fhs/etc/$f/"
        fi
      fi
    done

    # Create stub dirs/files PressureVessel expects but NixOS doesn't have
    mkdir -p /run/fhs/etc/ld.so.conf.d /run/fhs/etc/alternatives /run/fhs/etc/xdg /run/fhs/etc/pulse
    touch /run/fhs/etc/ld.so.cache /run/fhs/etc/ld.so.conf /run/fhs/etc/timezone

    mount --bind /run/fhs/etc /etc

    # FEX needs suid fusermount for rootfs overlay mounting
    mkdir -p /run/wrappers
    mount -t tmpfs -o exec,suid tmpfs /run/wrappers
    mkdir -p /run/wrappers/bin
    cp ${lib.getExe' fuse "fusermount"} /run/wrappers/bin/fusermount
    chown root:root /run/wrappers/bin/fusermount
    chmod u=srx,g=x,o=x /run/wrappers/bin/fusermount
  '';

  pythonEnv = python3.withPackages (ps: with ps; [ pyxdg ]);
in

stdenvNoCC.mkDerivation {
  pname = "steam-asahi";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/lib $out/share/steam-asahi

    # Include Steam bootstrap tarball in the package
    cp ${steamBootstrap} $out/share/steam-asahi/steam-bootstrap.tar.gz

    cp launcher.py $out/lib/steam-asahi-launcher.py

    substituteInPlace $out/lib/steam-asahi-launcher.py \
      --replace-fail "@muvm@" "${lib.getExe muvm}" \
      --replace-fail "@initScript@" "${initScript}" \
      --replace-fail "@fexRootFSFetcher@" "${fex}/bin/FEXRootFSFetcher" \
      --replace-fail "@steamBootstrap@" "$out/share/steam-asahi/steam-bootstrap.tar.gz"

    makeWrapper ${pythonEnv}/bin/python3 $out/bin/steam-asahi \
      --add-flags "$out/lib/steam-asahi-launcher.py"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Steam launcher for NixOS on Apple Silicon via muvm + FEX-Emu";
    license = licenses.mit;
    platforms = [ "aarch64-linux" ];
    mainProgram = "steam-asahi";
  };
}
