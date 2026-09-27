{ pkgs, sc }:
let
  version = "3.5.8";
  pin = {
    hash = "sha256-L+Jjivr1jKfPbG+ll1Z+hcZkbAZIfxwBKv8nXs8RLOE=";
  };
in
sc.mkSource {
  inherit version;
  key = "openssl";
  name = "openssl-${version}";
  upstream = sc.fetchSelectedArchive {
    url = "https://github.com/openssl/openssl/releases/download/openssl-${version}/openssl-${version}.tar.gz";
    inherit (pin) hash;
    selection.exclude = [
      {
        paths = [ "test" ];
        reason = "Unused with no-tests.";
      }
      {
        paths = [ "doc/" ];
        keep = [
          "doc/build.info"
          "doc/build.info.in"
          "doc/man1/build.info"
          "doc/perlvars.pm"
        ];
        reason = "Unused by build_libs and install_dev. Configure still reads the retained build descriptions.";
      }
    ];
  };
  tarHash = "sha256-YlReoISx8I4atVbLzvBsdlfV35ZtvDzdRjgjvErbhOI=";
  servicecacheFiles."libs/openssl" = ./.;
}
