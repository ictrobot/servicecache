{
  pkgs,
  sc,
  version,
  versionData,
  versionDirectory,
  loadableModules,
}:
let
  inherit (pkgs) lib;
  pin = versionData.upstream;
  directories = map (module: module.directory) loadableModules;
in
sc.mkSource {
  inherit version;
  key = "postgresql";
  name = "postgresql-${version}";
  upstream = sc.fetchSelectedGit {
    url = "https://github.com/postgres/postgres.git";
    inherit (pin) rev hash;
    selection.exclude = [
      {
        paths = [ "src/test" ];
        reason = "Unused as upstream tests are not built.";
      }
      {
        paths = [ "contrib/" ];
        keep = [ "contrib/contrib-global.mk" ] ++ builtins.filter (lib.hasPrefix "contrib/") directories;
        reason = "Unused as only the listed modules are built. Keep the makefile fragment they include.";
      }
      {
        paths = [ "src/pl/" ];
        keep = builtins.filter (lib.hasPrefix "src/pl/") directories;
        reason = "Unused as only the listed modules are built.";
      }
      {
        paths = map (name: "src/${name}/po") [
          "backend"
          "bin/psql"
          "bin/initdb"
          "interfaces/libpq"
        ];
        reason = "Unused with --disable-nls.";
      }
    ];
  };
  patches = sc.patchSeries (versionDirectory + "/patches");
  tarHash = versionData.tarHash;
  servicecacheFiles = {
    "services/postgresql/shared" = ./.;
    "services/postgresql/versions/${version}" = versionDirectory;
  };
}
