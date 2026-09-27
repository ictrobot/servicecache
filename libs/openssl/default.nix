{ pkgs, sc }:
let
  inherit (sc) toolchain;
  opensslSource = import ./source.nix { inherit pkgs sc; };
  smokeSource = sc.fetchSelectedArchive {
    selection = { };
    name = "openssl-smoke-source-${opensslSource.version}";
    inherit (opensslSource.upstream) url;
    hash = "sha256-+nGZI7TmmVJWRspbXQqpbDZFS/EkOFYXilQ6YCXqJ9s=";
  };
  recipe = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [
      ./build.sh
      ./wasix.conf
    ];
  };
  build = sc.mkGuestBuild {
    name = "openssl";
    version = opensslSource.version;
    sources.openssl = opensslSource;
    script = "${recipe}/build.sh";
    environment.SC_LIBRARY_DIR = recipe;
    nativeBuildInputs = [ pkgs.perl ];
  };
in
build.overrideAttrs (previous: {
  passthru = previous.passthru // {
    # This diagnostic builds upstream tests omitted from the service sources.
    smoke =
      pkgs.runCommand "smoke-openssl-${opensslSource.version}"
        (
          toolchain.environment
          // {
            nativeBuildInputs = toolchain.programs ++ [
              pkgs.python3Minimal
              pkgs.perl
            ];
            SC_TOOLCHAIN = toolchain.support;
            SC_PYTHON = "${pkgs.python3Minimal}/bin/python3";
            SC_SOURCE_OPENSSL_DIR = opensslSource.tree;
            SC_LIBRARY_DIR = recipe;
            SC_LIBRARY_OPENSSL_DIR = build;
            SC_OPENSSL_SMOKE_SOURCE_DIR = smokeSource;
          }
        )
        ''
          SC_BUILD_DIR="$NIX_BUILD_TOP/build" SC_OUT_DIR="$out" JOBS="$NIX_BUILD_CORES" \
            bash ${./smoke-build.sh} ${opensslSource.version}
        '';
  };
})
