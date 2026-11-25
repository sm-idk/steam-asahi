{
  lib,
  upstream,
  fetchFromGitHub,
  fetchurl,
  nix-update-script,
}:
let
  libkrunfwOverrideVersion = "5.6.4";
  # Track fixes within libkrunfw's supported 6.12 LTS kernel series
  libkrunfwKernelVersion = "6.12.119";
  # Keep libkrunfw's downstream drivers and TSI on the newer stable kernel
  kernelPatches = fetchurl {
    url = "https://github.com/libkrun/linux/compare/03bae623ec326c2738198739625832aab0eb120a...cb18e1849e6f8d8866f5e6f65fd428f1846726d4.diff";
    hash = "sha256-ZDzGQQwBohW16weU4aQFAttyRNicM1yCPjzCMVNZvEw=";
  };
  isCurrent = lib.versionAtLeast upstream.version libkrunfwOverrideVersion;
  overridden = upstream.overrideAttrs (
    finalAttrs: old: {
      version = libkrunfwOverrideVersion;
      src = fetchFromGitHub {
        owner = "libkrun";
        repo = "libkrunfw";
        tag = "v${finalAttrs.version}";
        hash = "sha256-jf8z5dIVIiE5YFElolDxij3k8c8nBeDPhnnCiuhb0YE=";
      };
      kernelSrc = fetchurl {
        url = "mirror://kernel/linux/kernel/v6.x/linux-${libkrunfwKernelVersion}.tar.xz";
        hash = "sha256-FDsoeWWsueJwCVuViU5Z4uujBtfh9rJg1Lp0/KcMAzM=";
      };
      postPatch = ''
        substituteInPlace Makefile \
          --replace-fail 'curl -L $(KERNEL_REMOTE) -o $(KERNEL_TARBALL)' 'ln -s ${finalAttrs.kernelSrc} $(KERNEL_TARBALL)' \
          --replace-fail 'tar xf $(KERNEL_TARBALL)' 'tar xf $(KERNEL_TARBALL) && patch --batch --fuzz=0 -p1 -d $(KERNEL_SOURCES) < ${kernelPatches}'
      '';
      makeFlags = (old.makeFlags or [ ]) ++ [
        "KERNEL_VERSION=${libkrunfwKernelVersion}"
        "KERNEL_TARBALL=tarballs/linux-${libkrunfwKernelVersion}.tar.xz"
        "KERNEL_SOURCES=linux-${libkrunfwKernelVersion}"
      ];
      passthru = (old.passthru or { }) // {
        updateScript = nix-update-script {
          attrPath = "libkrunfw";
          extraArgs = [
            "--flake"
            "--system=aarch64-linux"
            "--override-filename=pkgs/libkrunfw/override.nix"
          ];
        };
      };
    }
  );
in
lib.warnIf isCurrent ''
  libkrunfw >= ${libkrunfwOverrideVersion} is now in nixpkgs; remove the libkrunfw override.
'' (if isCurrent then upstream else overridden)
