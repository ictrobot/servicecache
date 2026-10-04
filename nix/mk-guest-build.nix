{
  pkgs,
  lib,
  toolchain,
  buildMetadata,
}@context:
{
  name,
  version,
  script,
  sources,
  toolchain ? context.toolchain,
  libraries ? { },
  extensions ? { },
  manifest ? null,
  nativeBuildInputs ? [ ],
  environment ? { },
}:
let
  metadata = import ./collect-metadata.nix { inherit lib; } (
    [ toolchain ]
    ++ builtins.attrValues sources
    ++ builtins.attrValues libraries
    ++ builtins.attrValues extensions
  );
  variable = kind: key: "SC_${kind}_${lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] key)}_DIR";
  inputs =
    kind: values: value:
    lib.mapAttrs' (key: item: lib.nameValuePair (variable kind key) (value item)) values;
  requiredPrograms = lib.unique (
    toolchain.requiredPrograms
    ++ [ pkgs.python3Minimal ]
    ++ nativeBuildInputs
    ++ lib.concatMap (source: source.requiredPrograms) (builtins.attrValues sources)
    ++ lib.concatMap (library: library.requiredPrograms or [ ]) (builtins.attrValues libraries)
    ++ lib.concatMap (extension: extension.requiredPrograms or [ ]) (builtins.attrValues extensions)
  );
  # The same build compiling through ccache, with the cache mounted at
  # /ccache. The compiler is identified by its version output, since its
  # store path changes with every toolchain rebuild.
  withCcache =
    build:
    build.overrideAttrs (previous: {
      name = "ccache-${previous.name}";
      nativeBuildInputs = previous.nativeBuildInputs ++ [ pkgs.ccache ];
      SC_CCACHE = "ccache";
      CCACHE_DIR = "/ccache";
      CCACHE_COMPILERCHECK = "%compiler% --version";
      CCACHE_UMASK = "000";
    });
  build =
    pkgs.runCommand "${name}-${version}"
      (
        toolchain.environment
        // inputs "SOURCE" sources (upstreamSource: upstreamSource.tree)
        // inputs "LIBRARY" libraries (library: library)
        // inputs "EXTENSION" extensions (extension: extension.directory)
        // environment
        // {
          nativeBuildInputs = toolchain.programs ++ [ pkgs.python3Minimal ] ++ nativeBuildInputs;
          SC_TOOLCHAIN = toolchain.support;
          SC_PYTHON = "${pkgs.python3Minimal}/bin/python3";
          passAsFile = [ "SERVICECACHE_METADATA" ];
          SERVICECACHE_METADATA = builtins.toJSON (
            toolchain.buildMetadata
            // {
              format = 1;
              metadata = buildMetadata;
              service = { inherit name version; };
              dependencies = lib.mapAttrs (_: dependency: dependency.version) (
                builtins.removeAttrs sources [ name ] // libraries
              );
            }
          );
          passthru = metadata // {
            inherit version sources requiredPrograms;
            ccache = withCcache build;
          };
        }
        // lib.optionalAttrs (manifest != null) {
          SC_MANIFEST = manifest;
        }
      )
      ''
        SC_BUILD_DIR="$NIX_BUILD_TOP/build" SC_OUT_DIR="$out" \
          JOBS="$NIX_BUILD_CORES" bash ${script} ${lib.escapeShellArg version}
      '';
in
build
