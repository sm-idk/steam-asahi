{
  lib,
  callPackage,
  stdenv,
  buildEnv,
  brotli,
  bzip2,
  glibc,
  pciutils,
  libvpx,
  libasyncns,
  libsndfile,
  libssh2,
  libva,
  libvdpau,
  alsa-lib,
  atk,
  at-spi2-atk,
  cairo,
  cups,
  curl,
  dbus,
  expat,
  fontconfig,
  freetype,
  fribidi,
  gdk-pixbuf,
  glib,
  gtk2,
  gtk3,
  ibus,
  krb5,
  libappindicator,
  libcap,
  libGL,
  libdrm,
  libgbm,
  libpulseaudio,
  libpng,
  libsecret,
  libthai,
  libusb1,
  libudev0-shim,
  libxkbcommon,
  libxcrypt,
  libxcb,
  libX11,
  libXcomposite,
  libXcursor,
  libXdamage,
  libXext,
  libXfixes,
  libXi,
  libXinerama,
  libXrandr,
  libXrender,
  libXScrnSaver,
  libXtst,
  libSM,
  libICE,
  networkmanager,
  nspr,
  nss,
  openal,
  openssl,
  pango,
  pipewire,
  SDL2,
  speechd-minimal,
  systemd,
  vulkan-loader,
  wayland,
  zlib,
  zstd,
}:
let
  gtk2Appindicator = callPackage ./gtk2/appindicator.nix {
    inherit gtk2 libappindicator;
  };

  # Steam's client runtime is not sufficient on its own: Pressure Vessel also
  # imports host libraries and runs host-side probes. Keep this list explicit,
  # like nixpkgs' Steam runtime, so every guest dependency is visible and
  # independently overridable through callPackage
  nativeLibraries = [
    glibc
    stdenv.cc.cc.lib
    brotli
    bzip2
    alsa-lib
    atk
    at-spi2-atk
    cairo
    cups
    curl
    dbus
    expat
    fontconfig
    freetype
    # SDL loads these by SONAME instead of relying on linked dependencies
    fribidi
    libthai
    wayland
    gdk-pixbuf
    glib
    gtk2
    gtk3
    ibus
    krb5
    gtk2Appindicator
    libcap
    libGL
    libdrm
    libgbm
    # CEF probes libpci in addition to invoking the lspci shim
    pciutils
    libpulseaudio
    libpng
    libsecret
    libusb1
    # SDL3 and CEF still probe the pre-udev-1 compatibility SONAME
    libudev0-shim
    libvpx
    # Valve's bundled libpulsecommon and libcurl retain these distro-facing
    # dependencies instead of shipping private copies
    libasyncns
    libsndfile
    libssh2
    openssl
    zstd
    libxkbcommon
    libxcrypt
    libxcb
    libX11
    libXcomposite
    libXcursor
    libXdamage
    libXext
    libXfixes
    libXi
    libXinerama
    libXrandr
    libXrender
    libXScrnSaver
    libXtst
    libSM
    libICE
    networkmanager
    nspr
    nss
    openal
    pango
    pipewire
    SDL2
    speechd-minimal
    systemd
    # CEF links these directly even when hardware decoding is unavailable
    libva
    libvdpau
    vulkan-loader
    zlib
  ];

in
buildEnv {
  name = "steam-arm64-native-runtime";
  paths = map lib.attrsets.getLib nativeLibraries;
  pathsToLink = [ "/lib" ];
  passthru = { inherit gtk2Appindicator; };
}
