{ sc }:
let
  version = "10.47";
  pin = {
    hash = "sha256-DRa3C1AU8+z28dM3Zta1Hn9WMgoHd0IHxRaAdoau2js=";
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
        patterns = [ "/deps/sljit/" ];
        reason = "Unused with PCRE2_SUPPORT_JIT=OFF.";
      }
      {
        patterns = [ "/doc/" ];
        reason = "Unused as documentation is not installed.";
      }
      {
        patterns = [ "/testdata/" ];
        reason = "Unused with PCRE2_BUILD_TESTS=OFF.";
      }
    ];
  };
  tarHash = "sha256-6YHJBZhvX2PKCPnD16XYGIczoM6dQ4Fu30mTiNLg/EE=";
  servicecacheFiles."services/mariadb/deps/pcre2" = ./.;
}
