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
  # Stock is the unpatched tag, so patch handling never invalidates it or the
  # target directory built from it. Patched sources share its name, "source",
  # so every variant unpacks at the same path.
  sourceFor =
    variant:
    if variant == "stock" then
      upstream
    else
      pkgs.applyPatches {
        name = "source";
        src = upstream;
        patches = lib.concatMap patchSeries (patchDirectories variant);
      };

  # Patched variants start from stock's target directory, kept as a zstd tar
  # in stock's artifacts output, so third-party crates compile once. Cargo
  # reuses a crate only if its path matches and nothing it depends on is
  # newer: every build uses stock's paths, restored files get one timestamp
  # after the vendored crates', and the variant's sources are touched later,
  # so only Wasmer's own crates, and any whose features a patch changes,
  # recompile. Incremental caches and cargo's lock files aren't carried over.
  saveTarget = ''
    mkdir -p "$artifacts"
    tar -C target -c --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner \
      --mode=u+w --exclude='*/incremental' . |
      zstd -q -T"$NIX_BUILD_CORES" -o "$artifacts/target.tar.zst"
  '';
  restoreTarget = stockBuild: ''
    mkdir -p target
    zstd -d -c ${stockBuild.artifacts}/target.tar.zst | tar -x -C target
    find target -name .cargo-lock -delete
    restored="$(date +%s.%N)"
    find target -exec touch -h -d "@$restored" {} +
    find . -path ./target -prune -o -type f -exec touch {} +
  '';
  # Saved before nixpkgs' install hook copies outputs around; restored before
  # cargo runs.
  shareTarget =
    variant: stockBuild:
    if variant == "stock" then
      {
        outputs = [
          "out"
          "artifacts"
        ];
        postBuild = saveTarget;
      }
    else
      { preBuild = restoreTarget stockBuild; };
  # Every crate in the variant's lockfile is its own download, keyed by its
  # checksum, so crates the variants share download once.
  cargoLockFor = variant: { lockFile = "${sourceFor variant}/Cargo.lock"; };
  buildFor =
    variant:
    pkgs.rustPlatform.buildRustPackage (
      {
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
        nativeBuildInputs = [ pkgs.zstd ];
        doCheck = false;
      }
      // shareTarget variant packages.stock
    );
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
    pkgs.rustPlatform.buildRustPackage (
      {
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
        nativeBuildInputs = [ pkgs.zstd ];
        installPhase = ''
          mkdir -p "$out"
          touch "$out/passed"
        '';
      }
      // shareTarget variant tests.stock
    );
  packages = lib.genAttrs variants buildFor;
  tests = lib.genAttrs variants testsFor;
in
{
  inherit packages tests;
}
