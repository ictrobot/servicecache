{ pkgs }:
let
  inherit (pkgs) lib;
  version = lib.removeSuffix "\n" (builtins.readFile ./version);
  patchSeries = import ../nix/patch-series.nix { inherit lib; };
  upstream = pkgs.fetchFromGitHub {
    owner = "wasmerio";
    repo = "wasmer";
    rev = "v${version}";
    fetchSubmodules = true;
    hash = "sha256-9QAMeROq9b4LnvZiNJjMWTY7Su54zovasHsruSG7bAA=";
  };
  variants = builtins.attrNames (
    lib.filterAttrs (
      name: type: type == "directory" && builtins.pathExists (./. + "/${name}/patches.list")
    ) (builtins.readDir ./.)
  );
  patchDirectories =
    variant:
    let
      lines = lib.splitString "\n" (builtins.readFile (./. + "/${variant}/patches.list"));
    in
    map (line: ../. + "/${line}") (builtins.filter (line: line != "" && !lib.hasPrefix "#" line) lines);
  sourceFor =
    variant:
    pkgs.applyPatches {
      name = "wasmer-${version}-${variant}-source";
      src = upstream;
      patches = lib.concatMap patchSeries (patchDirectories variant);
    };
  # Every crate in the variant's lockfile is its own download, keyed by its
  # checksum, so crates the variants share download once.
  cargoLockFor = variant: { lockFile = "${sourceFor variant}/Cargo.lock"; };
  buildFor =
    variant:
    pkgs.rustPlatform.buildRustPackage {
      pname = "wasmer-${variant}";
      inherit version;
      src = sourceFor variant;
      cargoLock = cargoLockFor variant;
      # Wasmer's build script queries cargo metadata; cargo-auditable asks for
      # unsupported optional-dependency feature names in this workspace.
      auditable = false;
      env.WASMER_REPRODUCIBLE_BUILD = "1";
      cargoBuildFlags = [
        "--manifest-path"
        "lib/cli/Cargo.toml"
        "--bin"
        "wasmer"
        "--features"
        "cranelift,wasmer-artifact-create,static-artifact-create,wasmer-artifact-load,static-artifact-load"
      ];
      doCheck = false;
    };
  testPackages = [
    "virtual-fs"
    "virtual-mio"
    "virtual-net"
    "wasmer"
    "wasmer-backend-api"
    "wasmer-cli"
    "wasmer-compiler"
    "wasmer-compiler-cranelift"
    "wasmer-config"
    "wasmer-derive"
    "wasmer-journal"
    "wasmer-package"
    "wasmer-sdk"
    "wasmer-sys-utils"
    "wasmer-types"
    "wasmer-wasix"
    "wasmer-wasix-types"
    "wasmer-wast"
  ];
  # The tests are packages rather than flake checks, so make lint does not
  # build them.
  testsFor =
    variant:
    pkgs.rustPlatform.buildRustPackage {
      pname = "wasmer-${variant}-tests";
      inherit version;
      src = sourceFor variant;
      cargoLock = cargoLockFor variant;
      auditable = false;
      env.WASMER_REPRODUCIBLE_BUILD = "1";
      doCheck = false;
      buildPhase = ''
        runHook preBuild
        export WASMER_DIR="$TMPDIR/wasmer"
        cargo test --offline --locked -j "$NIX_BUILD_CORES" --lib \
          -p wasmer-vm -- --test-threads=1
        # Two upstream tests contact the public registry, which the sandbox blocks.
        cargo test --offline --locked -j "$NIX_BUILD_CORES" --lib \
          ${lib.concatMapStringsSep " " (name: "-p ${name}") testPackages} \
          ${lib.optionalString (variant == "servicecache") "--features wasmer-wasix/direct-waits"} \
          -- --skip commands::package::download::tests::test_cmd_package_download \
          --skip runners::wasi::tests::test_volume_mount_with_webcs
        runHook postBuild
      '';
      installPhase = ''
        mkdir -p "$out"
        touch "$out/passed"
      '';
    };
in
{
  packages = lib.genAttrs variants buildFor;
  tests = lib.genAttrs variants testsFor;
}
