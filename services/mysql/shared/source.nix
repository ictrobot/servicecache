{
  pkgs,
  sc,
  version,
  versionData,
  versionDirectory,
}:
let
  inherit (pkgs) lib;
  pin = versionData.upstream;
in
sc.mkSource {
  inherit version;
  key = "mysql";
  name = "mysql-${version}";
  upstream = sc.fetchSelectedGit {
    url = "https://github.com/mysql/mysql-server.git";
    inherit (pin) rev hash;
    selection.exclude = [
      {
        patterns = [
          "/mysql-test/"
          "!/mysql-test/CMakeLists.txt"
          "!/mysql-test/mtr.out-of-source"
          "!/mysql-test/lib/My/SafeProcess/"
        ];
        reason = "Unused by the selected targets. CMake still configures the retained files.";
      }
      {
        patterns = [
          "/unittest/"
          "/extra/googletest/"
        ];
        reason = "Unused with WITH_UNIT_TESTS=OFF.";
      }
      {
        patterns = [
          "/router/"
          "!/router/src/harness/include/"
          "!/router/LICENSE.router"
          "!/router/README.router"
          "!/router/src/harness/README.txt"
        ];
        reason = "Unused with WITH_ROUTER=OFF. Keep the headers CMake configures, their licence, and the Router and harness READMEs.";
      }
      {
        patterns = [ "/storage/ndb/" ];
        reason = "Unused with WITH_NDB=OFF and WITH_NDBCLUSTER=OFF.";
      }
      {
        patterns = [ "/plugin/group_replication/" ];
        reason = "Unused as the plugin has a separate build target.";
      }
      {
        patterns = [ "/plugin/x/" ];
        reason = "Unused with WITH_MYSQLX=OFF.";
      }
      {
        patterns = [ "/extra/gperftools/" ];
        reason = "Unused with WITH_TCMALLOC=OFF.";
      }
      {
        patterns = [ "/extra/tirpc/" ];
        reason = "Unused without WITH_TIRPC=bundled.";
      }
      {
        patterns = [ "/extra/libedit/" ];
        reason = "Unused with WITH_EDITLINE=none.";
      }
      {
        patterns = [
          "/extra/libfido2/"
          "/extra/libcbor/"
        ];
        reason =
          if lib.hasPrefix "8.0." version then
            "Unused with WITH_AUTHENTICATION_FIDO=OFF and WITH_AUTHENTICATION_CLIENT_PLUGINS=OFF."
          else
            "Unused with WITH_AUTHENTICATION_WEBAUTHN=OFF and WITH_AUTHENTICATION_CLIENT_PLUGINS=OFF.";
      }
    ];
  };
  patches =
    sc.patchSeries (versionDirectory + "/patches")
    ++ sc.patchSeries (versionDirectory + "/patches/protobuf")
    ++ sc.patchSeries (versionDirectory + "/patches/libmysql")
    ++ lib.optionals (version == "9.7.2") (sc.patchSeries (versionDirectory + "/patches/abseil"));
  tarHash = versionData.tarHash;
  servicecacheFiles = {
    "services/mysql/shared" = ./.;
    "services/mysql/versions/${version}" = versionDirectory;
  };
}
