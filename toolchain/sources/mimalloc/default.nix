{ pkgs, sc }:
let
  version = "v3.5.3";
  pin = {
    rev = "d4881d338125e1cb7c47ba4cfb398d6f7c0c8d45";
    hash = "sha256-p9DdPnKrViL70Wx27AttD2/KEEolsC0LO16gycx2vgE=";
  };
in
sc.mkSource {
  inherit version;
  key = "mimalloc";
  name = "mimalloc-${version}";
  upstream = sc.fetchSelectedArchive {
    url = "https://github.com/microsoft/mimalloc/archive/${pin.rev}.tar.gz";
    inherit (pin) hash;
    selection.exclude = [
      {
        paths = [ "bin" ];
        reason = "Unused outside Windows.";
      }
      {
        paths = [
          "doc"
          "docs"
        ];
        reason = "Unused as documentation is not built or installed.";
      }
      {
        paths = [ "ide" ];
        reason = "Unused by the Makefile build.";
      }
      {
        paths = [ "test" ];
        reason = "Unused as upstream tests are not built.";
      }
    ];
  };
  patches = sc.patchSeries ./patches;
  tarHash = "sha256-hK2JSpXDY9oh2UdGflz3VCpimpDokLKARm7HqmCMaIU=";
  servicecacheFiles."toolchain/sources/mimalloc" = ./.;
}
