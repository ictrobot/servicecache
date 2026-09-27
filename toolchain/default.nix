# The pinned upstream compiler, guest sysroot and compiler wrappers.
{
  pkgs,
  sc,
}:
let
  inherit (pkgs) lib;
  sources = lib.genAttrs [ "wasix-libc" "mimalloc" "llvm-project" ] (
    name: import (./sources + "/${name}") { inherit pkgs sc; }
  );
  metadata = sc.collectMetadata (builtins.attrValues sources);
  support = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions (
      map (path: ./. + "/${path}") [
        "guest-lib.sh"
        "guest/toolchain.cmake"
        "guest/no-pic.cmake"
        "guest_artifacts.py"
      ]
    );
  };
  runtimeRelease = sources.llvm-project.version;
  libcRelease = sources.wasix-libc.version;
  mimallocRelease = sources.mimalloc.version;
  compiler = pkgs.llvmPackages_23;
  compilerDirectories = {
    SC_CLANG_DIR = compiler.clang-unwrapped;
    SC_LLD_DIR = compiler.lld;
    SC_LLVM_DIR = compiler.llvm;
  };
  script =
    name:
    builtins.path {
      path = ./. + "/${name}";
      inherit name;
    };

  libc =
    pkgs.runCommand "wasix-libc-${libcRelease}"
      (
        compilerDirectories
        // {
          SC_SOURCE_WASIX_LIBC_DIR = sources.wasix-libc.tree;
          SC_SOURCE_MIMALLOC_DIR = sources.mimalloc.tree;
        }
      )
      ''
        SC_BUILD_DIR="$NIX_BUILD_TOP/build" SC_OUT_DIR="$out" JOBS="$NIX_BUILD_CORES" \
          bash ${script "libc.sh"}
      '';
  runtime =
    pkgs.runCommand "llvm-runtime-${runtimeRelease}"
      (
        compilerDirectories
        // {
          SC_SOURCE_LLVM_PROJECT_DIR = sources.llvm-project.tree;
          nativeBuildInputs = [
            pkgs.cmakeMinimal
            pkgs.python3Minimal
          ];
          SC_LIBC_DIR = libc;
        }
      )
      ''
        SC_BUILD_DIR="$NIX_BUILD_TOP/build" SC_OUT_DIR="$out" JOBS="$NIX_BUILD_CORES" \
          bash ${script "runtime.sh"}
      '';
  # The sysroot guests are compiled and linked against.
  sysroot = pkgs.runCommand "wasix-sysroot" { } ''
    bash ${script "sysroot.sh"} ${libc} ${runtime} "$out"
  '';

  # What the assembly reads of the ServiceCache source: the script and the
  # configuration file it fills in, and not the CMake files beside them.
  assembly = lib.fileset.toSource {
    root = ./. + "/guest";
    fileset = lib.fileset.unions [
      (./. + "/guest/assemble.sh")
      (./. + "/guest/guest.cfg")
    ];
  };
  guest =
    pkgs.runCommand "guest-toolchain"
      (
        compilerDirectories
        // {
          SC_SYSROOT_DIR = sysroot;
        }
      )
      ''
        SC_OUT_DIR="$out" bash ${assembly}/assemble.sh
      '';

  programs = [
    guest
    pkgs.binaryen
  ];
  requiredPrograms = [
    compiler.clang-unwrapped
    compiler.lld
    compiler.llvm
    pkgs.cmakeMinimal
    pkgs.python3Minimal
    pkgs.binaryen
  ]
  ++ lib.concatMap (source: source.requiredPrograms) (builtins.attrValues sources);
  environment = {
    SC_SYSROOT_DIR = "${sysroot}";
  };
in
assert lib.versions.major compiler.release_version == lib.versions.major runtimeRelease;
{
  inherit
    sources
    support
    libc
    runtime
    sysroot
    guest
    programs
    requiredPrograms
    environment
    ;

  buildMetadata = {
    target = "wasm32-wasix";
    tools = {
      compiler = compiler.clang-unwrapped.version;
      linker = compiler.lld.version;
      wasm_opt = pkgs.binaryen.version;
      wasix_sysroot = libcRelease;
      mimalloc = mimallocRelease;
      llvm_runtime = runtimeRelease;
      debug_info = "names";
    };
  };

  inherit (metadata) upstreamSources;
  servicecacheFiles =
    metadata.servicecacheFiles
    // lib.listToAttrs (
      map (name: lib.nameValuePair "toolchain/${name}" (./. + "/${name}")) [
        "default.nix"
        "guest"
        "guest-lib.sh"
        "guest_artifacts.py"
        "libc.sh"
        "runtime.sh"
        "sysroot.sh"
      ]
    );

  smoke = pkgs.runCommand "toolchain-smoke" { nativeBuildInputs = programs; } ''
    SC_OUT_DIR="$out" bash ${script "smoke"}/build.sh
  '';
}
