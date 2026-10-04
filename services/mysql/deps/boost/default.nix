{ sc }:
let
  version = "1.77.0";
  pin = {
    hash = "sha256-7NWfPG2vV8VodUvvo/SR9vzOCjOAeDxBQwEDkzcgeak=";
  };
  # The archive unpacks to this directory, which MySQL expects inside WITH_BOOST.
  directory = "boost_${builtins.replaceStrings [ "." ] [ "_" ] version}";
in
sc.mkSource {
  inherit version;
  key = "boost";
  name = "boost-${version}";
  upstream = sc.fetchSelectedArchive {
    stripRoot = false;
    url = "https://archives.boost.io/release/${version}/source/${directory}.tar.bz2";
    inherit (pin) hash;
    selection.exclude = [
      {
        patterns = map (name: "/${directory}/${name}/") [
          "libs"
          "doc"
          "tools"
          "status"
        ];
        reason = "Unused as only headers are consumed.";
      }
    ];
  };
  tarHash = "sha256-fWCeduWA93YAOaLFmU/z3s3UT0/cgymXMlW7up69ack=";
  servicecacheFiles."services/mysql/deps/boost" = ./.;
}
