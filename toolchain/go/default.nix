# The toolchain Go guests are built with: the pinned Go release with the
# wasix series applied, built from source by make.bash with nixpkgs' Go as
# bootstrap. It presents the same interface as ../default.nix, so a Go
# service's package selects it as its toolchain.
{
  pkgs,
  sc,
}:
let
  inherit (pkgs) lib;
  source = import ../sources/go { inherit pkgs sc; };
  metadata = sc.collectMetadata [ source ];
  bootstrap = pkgs.go;
  support = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../guest-lib.sh
      ../guest_artifacts.py
    ];
  };
  # Every guest is a wasip1 module built with the wasix tag; modules are
  # resolved from the vendor tree beside its sources and nothing is fetched.
  environment = {
    GOOS = "wasip1";
    GOARCH = "wasm";
    GOFLAGS = "-tags=wasix -mod=vendor -trimpath -buildvcs=false";
    GOTOOLCHAIN = "local";
    GOPROXY = "off";
    GOSUMDB = "off";
    CGO_ENABLED = "0";
  };
  # The installation carries the guest environment as servicecache.env, for
  # a shell that uses it outside a guest build to source.
  build =
    name: tree:
    pkgs.runCommand name
      {
        SC_SOURCE_GO_DIR = tree;
        SC_GO_BOOTSTRAP_DIR = bootstrap;
      }
      ''
        SC_BUILD_DIR="$NIX_BUILD_TOP/build" SC_OUT_DIR="$out" JOBS="$NIX_BUILD_CORES" \
          bash ${./go.sh}
        cat > "$out/servicecache.env" <<'EOF'
        ${lib.toShellVars environment}
        EOF
      '';
  go = build "go-wasix-${source.version}" source.tree;
in
rec {
  inherit
    source
    support
    go
    environment
    ;

  # What test.sh runs Go's own tests with: the same toolchain built from the
  # release with its tests.
  tests = build "go-wasix-${source.version}-with-tests" source.withTests;

  programs = [
    go
    pkgs.binaryen
  ];
  requiredPrograms = [
    bootstrap
    pkgs.binaryen
  ]
  ++ source.requiredPrograms;
  buildMetadata = {
    target = "wasm32-wasip1";
    tools = {
      go = source.version;
      debug_info = "names";
    };
  };

  inherit (metadata) upstreamSources;
  servicecacheFiles = metadata.servicecacheFiles // {
    "toolchain/go/default.nix" = ./default.nix;
    "toolchain/go/go.sh" = ./go.sh;
    "toolchain/guest-lib.sh" = ../guest-lib.sh;
    "toolchain/guest_artifacts.py" = ../guest_artifacts.py;
  };
}
