{ pkgs, sc }:
let
  version = "1.26.7";
  pin = {
    hash = "sha256-IGEJM/zO6qpoMorM2AIwYS8DQ3oZ7pVBuN2kVdQyTgI=";
    withTestsHash = "sha256-jUpg5mpcO9/UDol+NU5Wv5NqcSDEKz+1Vj0nz47ASJM=";
  };
  url = "https://go.dev/dl/go${version}.src.tar.gz";
  patches = sc.patchSeries ./patches;
in
sc.mkSource {
  inherit version;
  key = "go";
  name = "go-${version}";
  upstream = sc.fetchSelectedArchive {
    inherit url;
    inherit (pin) hash;
    selection.exclude = [
      {
        patterns = [
          "/api/"
          "/doc/"
          "/misc/"
        ];
        reason = "Unused by the /src/ build.";
      }
      {
        patterns = [
          "/src/crypto/internal/boring/"
          "!/src/crypto/internal/boring/**/*.go"
          "!/src/crypto/internal/boring/**/*.s"
        ];
        reason = "Unused without GOEXPERIMENT=boringcrypto. Keep the Go licensed files, including the stub every build compiles.";
      }
      {
        patterns = [
          "/src/runtime/race/"
          "!/src/runtime/race/**/*.go"
        ];
        reason = "Unused without -race, which has no wasm port. Keep the Go licensed files.";
      }
      {
        patterns = [
          "/test/"
          "*_test.go"
          "testdata/"
        ];
        reason = "Unused by the guest toolchain.";
      }
    ];
  };
  inherit patches;
  tarHash = "sha256-VtuezZecn9QooSjGaPvD2sHWafILG08hGsLK3wYF548=";
  servicecacheFiles."toolchain/sources/go" = ./.;
}
// {
  # The release with nothing left out and the series applied, for Go's own
  # tests, which the selection above leaves out. Nothing a guest is built
  # from comes from it.
  withTests =
    pkgs.runCommand "go-${version}-with-tests"
      {
        inherit patches;
        nativeBuildInputs = [ pkgs.gitMinimal ];
      }
      ''
        cp -r ${
          pkgs.fetchzip {
            inherit url;
            hash = pin.withTestsHash;
          }
        } source
        chmod -R u+w source
        cd source
        for patch in $patches; do
          git apply --whitespace=error-all "$patch"
        done
        cp -r --preserve=mode . "$out"
      '';
}
