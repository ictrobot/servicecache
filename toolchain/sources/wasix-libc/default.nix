{ pkgs, sc }:
let
  version = "v2026-07-30.1";
  pin = {
    rev = "67b2eccf84e5091912ee28f4b6bc0edd1b88e86f";
    hash = "sha256-dMCO457Gk59vNS7u7RYLb2aXeugbOLoKoIY0u+uOm3Y=";
  };
in
sc.mkSource {
  inherit version;
  key = "wasix-libc";
  name = "wasix-libc-${version}";
  upstream = sc.fetchSelectedArchive {
    url = "https://github.com/wasix-org/wasix-libc/archive/${pin.rev}.tar.gz";
    inherit (pin) hash;
    selection.exclude = [
      {
        patterns = [ "/expected/" ];
        reason = "Unused with CHECK_SYMBOLS=no.";
      }
    ];
  };
  patches = sc.patchSeries ./patches;
  tarHash = "sha256-mm6EDBh5e+6T1Q+e6yKQPQ9T9BAG+va0Zo3s6UJBEO8=";
  servicecacheFiles."toolchain/sources/wasix-libc" = ./.;
}
