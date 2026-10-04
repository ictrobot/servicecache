{
  sc,
  sourceData,
  versionDirectory,
}:
let
  pin = sourceData.upstream;
in
sc.mkSource {
  version = pin.rev;
  key = "libmariadb";
  name = "libmariadb-${builtins.substring 0 12 pin.rev}";
  upstream = sc.fetchSelectedArchive {
    url = "https://github.com/MariaDB/mariadb-connector-c/archive/${pin.rev}.tar.gz";
    inherit (pin) hash;
    passthru = {
      inherit (pin) rev;
      gitRepoUrl = "https://github.com/MariaDB/mariadb-connector-c.git";
    };
    selection.exclude = [
      {
        patterns = [ "/win/" ];
        reason = "Unused without WIN32.";
      }
    ];
  };
  patches = sc.patchSeries (versionDirectory + "/patches/libmariadb");
  tarHash = sourceData.tarHash;
  servicecacheFiles."services/mariadb/deps/libmariadb" = ./.;
}
