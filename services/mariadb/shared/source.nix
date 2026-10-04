{
  sc,
  version,
  versionData,
  versionDirectory,
  libmariadbSource,
  wolfsslSource,
}:
let
  pin = versionData.upstream;
in
sc.mkSource {
  inherit version;
  key = "mariadb";
  name = "mariadb-${version}";
  upstream = sc.fetchSelectedGit {
    url = "https://github.com/MariaDB/server.git";
    inherit (pin) rev hash;
    branchName = "mariadb-${version}";
    fetchSubmodules = false;
    postCheckout = ''
      git -C "$out" ls-tree HEAD libmariadb | grep -Fx $'160000 commit ${libmariadbSource.upstream.rev}\tlibmariadb'
      git -C "$out" ls-tree HEAD extra/wolfssl/wolfssl | grep -Fx $'160000 commit ${wolfsslSource.upstream.rev}\textra/wolfssl/wolfssl'
      test "$(git config -f "$out/.gitmodules" submodule.libmariadb.url)" = ${libmariadbSource.upstream.gitRepoUrl}
      test "$(git config -f "$out/.gitmodules" submodule.extra/wolfssl/wolfssl.url)" = ${wolfsslSource.upstream.gitRepoUrl}
    '';
    selection.exclude = [
      {
        patterns = [
          "/mysql-test/"
          "!/mysql-test/CMakeLists.txt"
          "!/mysql-test/mtr.out-of-source"
          "!/mysql-test/mariadb-stress-test.pl"
          "!/mysql-test/lib/My/SafeProcess/"
          "!/mysql-test/std_data/unicode/allkeys1400.txt"
        ];
        reason = "Unused by the selected targets. Keep the files CMake configures and the Unicode data used to generate collation tables.";
      }
      {
        patterns = [ "/storage/mroonga/" ];
        reason = "Unused with PLUGIN_MROONGA=NO.";
      }
      {
        patterns = [ "/storage/connect/" ];
        reason = "Unused with PLUGIN_CONNECT=NO.";
      }
      {
        patterns = [ "/storage/rocksdb/" ];
        reason = "Unused with PLUGIN_ROCKSDB=NO.";
      }
      {
        patterns = [ "/storage/spider/" ];
        reason = "Unused with PLUGIN_SPIDER=NO.";
      }
      {
        patterns = [ "/unittest/" ];
        reason = "Unused with WITH_UNIT_TESTS=OFF and WITH_EMBEDDED_SERVER=OFF.";
      }
      {
        patterns = [ "/debian/" ];
        reason = "Unused with DEB=OFF.";
      }
    ];
  };
  patches = sc.patchSeries (versionDirectory + "/patches");
  tarHash = versionData.tarHash;
  servicecacheFiles = {
    "services/mariadb/shared" = ./.;
    "services/mariadb/versions/${version}" = versionDirectory;
  };
}
