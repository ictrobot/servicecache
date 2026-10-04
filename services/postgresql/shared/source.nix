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
  moduleDirectories = map (module: module.directory) loadableModules;
  keepModulesUnder =
    prefix:
    map (directory: "!/${directory}/") (builtins.filter (lib.hasPrefix prefix) moduleDirectories);
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
        patterns = [ "/src/test/" ];
        reason = "Unused as upstream tests are not built.";
      }
      {
        patterns = [
          "/contrib/"
          "!/contrib/contrib-global.mk"
        ]
        ++ keepModulesUnder "contrib/";
        reason = "Unused as only the listed modules are built. Keep the makefile fragment they include.";
      }
      {
        patterns = [ "/src/pl/" ] ++ keepModulesUnder "src/pl/";
        reason = "Unused as only the listed modules are built.";
      }
      {
        patterns = map (name: "/src/${name}/po/") [
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
