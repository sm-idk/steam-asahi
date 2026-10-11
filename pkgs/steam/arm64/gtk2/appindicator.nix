{
  gtk2,
  gtk3,
  libappindicator,
  libindicator-gtk3,
  libdbusmenu-gtk3,
}:

let
  replaceDependency =
    oldDependency: newDependency: dependencies:
    map (dependency: if dependency == oldDependency then newDependency else dependency) dependencies;

  replaceGtk3 = replaceDependency gtk3 gtk2;

  gtk2ConfigureFlags =
    extraFlags: flags:
    map (flag: if flag == "--with-gtk=3" then "--with-gtk=2" else flag) flags ++ extraFlags;

  setMetadata = pname: pkgConfigModules: old: {
    inherit pname;
    meta = old.meta // {
      inherit pkgConfigModules;
    };
  };

  # Build private GTK2 variants for Steam. Recent nixpkgs removed the public
  # GTK2 attributes, while older revisions expose a different override API, so
  # alter the resolved GTK3 derivations instead of overriding package arguments.
  indicator = libindicator-gtk3.overrideAttrs (
    old:
    setMetadata "libindicator-gtk2" [ "indicator-0.4" ] old
    // {
      buildInputs = replaceGtk3 (old.buildInputs or [ ]);
      configureFlags = gtk2ConfigureFlags [ ] old.configureFlags;
    }
  );

  dbusmenu = libdbusmenu-gtk3.overrideAttrs (
    old:
    setMetadata "libdbusmenu-gtk2" [
      "dbusmenu-glib-0.4"
      "dbusmenu-jsonloader-0.4"
      "dbusmenu-gtk-0.4"
    ] old
    // {
      buildInputs = replaceGtk3 (old.buildInputs or [ ]);
      propagatedBuildInputs = replaceGtk3 (old.propagatedBuildInputs or [ ]);
      configureFlags = gtk2ConfigureFlags [
        "--disable-introspection"
        "--disable-vala"
      ] old.configureFlags;
    }
  );

  replaceAppindicatorDependencies =
    dependencies:
    replaceDependency libdbusmenu-gtk3 dbusmenu (
      replaceDependency libindicator-gtk3 indicator (replaceGtk3 dependencies)
    );
in
libappindicator.overrideAttrs (
  old:
  setMetadata "libappindicator-gtk2" [ "appindicator-0.1" ] old
  // {
    buildInputs = replaceAppindicatorDependencies (old.buildInputs or [ ]);
    propagatedBuildInputs = replaceAppindicatorDependencies (old.propagatedBuildInputs or [ ]);
    configureFlags = gtk2ConfigureFlags [
      "--disable-introspection"
      "--disable-vala"
    ] old.configureFlags;
  }
)
