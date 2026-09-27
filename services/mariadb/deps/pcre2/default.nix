{ sc }:
let
  version = "10.47";
  pin = {
    hash = "sha256-dnCsMBQsx2SVkZp2MYNqltcxl6zCXcem1JgN1f2iubE=";
  };
in
sc.mkSource {
  inherit version;
  key = "pcre2";
  name = "pcre2-${version}";
  upstream = sc.fetchSelectedArchive {
    url = "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${version}/pcre2-${version}.zip";
    inherit (pin) hash;
    selection.exclude = [
      {
        paths = [ "deps/sljit" ];
        reason = "Unused with PCRE2_SUPPORT_JIT=OFF.";
      }
      {
        paths = [ "doc" ];
        reason = "Unused as documentation is not installed.";
      }
      {
        paths = [ "testdata" ];
        reason = "Unused with PCRE2_BUILD_TESTS=OFF.";
      }
    ];
  };
  tarHash = "sha256-NCKBnhqSDlocojb71xiq6YduH4B945mJ2sOCA3hff68=";
  servicecacheFiles."services/mariadb/deps/pcre2" = ./.;
}
