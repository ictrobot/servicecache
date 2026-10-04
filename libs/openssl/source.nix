{ pkgs, sc }:
let
  version = "3.5.8";
  pin = {
    hash = "sha256-tq2Abipt212YFpOLm7NVc4V0nca5+TDd72OOickfGNo=";
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
        patterns = [ "/test/" ];
        reason = "Unused with no-tests.";
      }
      {
        patterns = [
          "/doc/"
          "!/doc/build.info"
          "!/doc/build.info.in"
          "!/doc/man1/build.info"
          "!/doc/perlvars.pm"
        ];
        reason = "Unused by build_libs and install_dev. Configure still reads the retained build descriptions.";
      }
    ];
  };
  tarHash = "sha256-AAK4MirKn+ivGA7yJmuvNCoXe1auY70JJKEDMAdo3fs=";
  servicecacheFiles."libs/openssl" = ./.;
}
