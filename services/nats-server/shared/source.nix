{
  sc,
  version,
  versionData,
  versionDirectory,
}:
let
  pin = versionData.upstream;
in
# The upstream source, unpatched.
sc.mkSource {
  inherit version;
  key = "nats-server";
  name = "nats-server-${version}";
  upstream = sc.fetchSelectedArchive {
    url = "https://github.com/nats-io/nats-server/archive/${pin.rev}.tar.gz";
    inherit (pin) hash;
    selection.exclude = [
      {
        patterns = [ "/test/" ];
        reason = "Unused as upstream tests are not run.";
      }
      {
        patterns = [
          "/docker/"
          "/logos/"
          "/scripts/"
        ];
        reason = "Unused by go build: container images, artwork and release scripts.";
      }
    ];
  };
  tarHash = versionData.tarHash;
  servicecacheFiles = {
    "services/nats-server/shared" = ./.;
    "services/nats-server/versions/${version}" = versionDirectory;
  };
}
