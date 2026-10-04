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
  key = "valkey";
  name = "valkey-${version}";
  upstream = sc.fetchSelectedArchive {
    url = "https://github.com/valkey-io/valkey/archive/${pin.rev}.tar.gz";
    inherit (pin) hash;
    selection.exclude = [
      {
        patterns = [
          "/tests/"
        ]
        ++ lib.optional (builtins.elem version [
          "8.1.9"
          "9.1.1"
        ]) "/src/unit/"
        ++ lib.optional (version == "9.1.1") "/deps/libvalkey/tests/";
        reason = "Unused as upstream tests are not built.";
      }
      {
        patterns = [ "/deps/jemalloc/" ];
        reason = "Unused with MALLOC=libc.";
      }
      {
        patterns = [ "/deps/lua/doc/" ];
        reason = "Unused by the library build.";
      }
    ]
    ++ lib.optional (version == "8.1.9") {
      patterns = [
        "/deps/fast_float/"
        "/deps/fast_float_c_interface/"
      ];
      reason = "Unused with USE_FAST_FLOAT=no.";
    };
  };
  patches = sc.patchSeries (versionDirectory + "/patches");
  tarHash = versionData.tarHash;
  servicecacheFiles = {
    "services/valkey/shared" = ./.;
    "services/valkey/versions/${version}" = versionDirectory;
  };
}
