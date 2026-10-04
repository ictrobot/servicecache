{ sc }:
let
  version = "12.2.0";
  pin = {
    hash = "sha256-9jMaqTZWMjnD8UANmfcyD9mLCXJjrbBdTe7gEftM3V8=";
  };
in
sc.mkSource {
  inherit version;
  key = "fmt";
  name = "fmt-${version}";
  upstream = sc.fetchSelectedArchive {
    url = "https://github.com/fmtlib/fmt/releases/download/${version}/fmt-${version}.zip";
    inherit (pin) hash;
    selection.exclude = [
      {
        patterns = [ "/doc-html/" ];
        reason = "Unused as documentation is not installed.";
      }
      {
        patterns = [ "/support/" ];
        reason = "Unused as release tooling is not run.";
      }
      {
        patterns = [ "/test/" ];
        reason = "Unused as upstream tests are not built.";
      }
    ];
  };
  tarHash = "sha256-+5nxai/uBVfiFrkmwBWXQmQYe4+uYTi1/uD1L8SR8lg=";
  servicecacheFiles."services/mariadb/deps/fmt" = ./.;
}
