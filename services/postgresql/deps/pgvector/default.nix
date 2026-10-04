{ sc }:
let
  version = "0.8.6";
  pin = {
    hash = "sha256-1sNR0M71OA786LUa/MxqJcXyJXH4fZIOtJMc7j8pnWg=";
  };
in
sc.mkSource {
  inherit version;
  key = "pgvector";
  name = "pgvector-${version}";
  upstream = sc.fetchSelectedArchive {
    url = "https://github.com/pgvector/pgvector/archive/refs/tags/v${version}.tar.gz";
    inherit (pin) hash;
    selection.exclude = [
      {
        patterns = [ "/test/" ];
        reason = "Unused as upstream tests are not built.";
      }
    ];
  };
  tarHash = "sha256-waOjDdoFeqJDhBnNQgAXvpW1fLaUz8K15cz3ywio8yw=";
  servicecacheFiles."services/postgresql/deps/pgvector" = ./.;
}
