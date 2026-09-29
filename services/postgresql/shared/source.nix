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
        paths = [ "contrib" ];
        reason = "Unused as contrib modules are not built.";
      }
      {
        paths = [ "src/pl/" ];
        keep = builtins.filter (lib.hasPrefix "src/pl/") (map (module: module.directory) loadableModules);
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
