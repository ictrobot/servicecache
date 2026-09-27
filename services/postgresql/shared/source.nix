{
  sc,
  version,
  versionData,
  versionDirectory,
}:
let
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
        paths = [
          "contrib"
          "src/pl"
        ];
        reason = "Unused as loadable modules are not built.";
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
