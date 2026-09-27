{ pkgs, sc }:
let
  version = "v2026-07-30.1";
  pin = {
    rev = "67b2eccf84e5091912ee28f4b6bc0edd1b88e86f";
    hash = "sha256-RMFNPXe1gKgqbX9W6fY518jf1mSXEOMa6YifsP6Z5HE=";
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
        paths = [ "expected" ];
        reason = "Unused with CHECK_SYMBOLS=no.";
      }
    ];
  };
  patches = sc.patchSeries ./patches;
  tarHash = "sha256-FJH7k/G93FDAA5n3G1Z9hSsFOmBYsL8Crw1FkSw+10g=";
  servicecacheFiles."toolchain/sources/wasix-libc" = ./.;
}
