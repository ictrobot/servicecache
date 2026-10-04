{
  sc,
  version,
  versionData,
  versionDirectory,
}:
let
  pin = versionData.upstream;
in
sc.mkSource {
  inherit version;
  key = "beanstalkd";
  name = "beanstalkd-${version}";
  upstream = sc.fetchSelectedArchive {
    url = "https://github.com/beanstalkd/beanstalkd/archive/${pin.rev}.tar.gz";
    inherit (pin) hash;
    selection.exclude = [
      {
        patterns = [ "/ct/" ];
        reason = "Unused by make all.";
      }
    ];
  };
  patches = sc.patchSeries (versionDirectory + "/patches");
  tarHash = versionData.tarHash;
  servicecacheFiles = {
    "services/beanstalkd/shared" = ./.;
    "services/beanstalkd/versions/${version}" = versionDirectory;
  };
}
