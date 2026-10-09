{
  gtk2,
  libappindicator,
  libindicator,
  libdbusmenu-gtk3,
}:

let
  # Steam builds its tray menu with GTK2 and loads libappindicator.so.1; keep
  # all three libraries on GTK2 because nixpkgs now defaults to GTK3
  useGtk2 =
    pname: pkgConfigModules: package:
    package.overrideAttrs (old: {
      inherit pname;
      # Steam uses the C ABI; omit language bindings and their GIR scanner
      configureFlags =
        map (flag: if flag == "--with-gtk=3" then "--with-gtk=2" else flag) old.configureFlags
        ++ (
          if pname == "libindicator-gtk2" then
            [ ]
          else
            [
              "--disable-introspection"
              "--disable-vala"
            ]
        );
      meta = old.meta // {
        inherit pkgConfigModules;
      };
    });

  dbusmenu = useGtk2 "libdbusmenu-gtk2" [
    "dbusmenu-glib-0.4"
    "dbusmenu-jsonloader-0.4"
    "dbusmenu-gtk-0.4"
  ] (libdbusmenu-gtk3.override { gtk3 = gtk2; });

  indicator = useGtk2 "libindicator-gtk2" [ "indicator-0.4" ] (
    libindicator.override { gtk3 = gtk2; }
  );
in
useGtk2 "libappindicator-gtk2" [ "appindicator-0.1" ] (
  libappindicator.override {
    gtk3 = gtk2;
    libindicator = indicator;
    libdbusmenu-gtk3 = dbusmenu;
  }
)
