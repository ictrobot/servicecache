{
  pkgs,
  lib,
  toolchain,
  buildMetadata,
}:
{
  name,
  version,
  script,
  sources,
  manifest,
  nativeBuildInputs ? [ ],
}:
let
  metadata = import ./collect-metadata.nix { inherit lib; } (
    [ toolchain ] ++ builtins.attrValues sources
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
  );
in
pkgs.runCommand "${name}-${version}"
  (
    toolchain.environment
    // inputs "SOURCE" sources (upstreamSource: upstreamSource.tree)
    // {
      nativeBuildInputs = toolchain.programs ++ [ pkgs.python3Minimal ] ++ nativeBuildInputs;
      SC_TOOLCHAIN = toolchain.support;
      SC_PYTHON = "${pkgs.python3Minimal}/bin/python3";
      SC_MANIFEST = manifest;
      passAsFile = [ "SERVICECACHE_METADATA" ];
      SERVICECACHE_METADATA = builtins.toJSON (
        toolchain.buildMetadata
        // {
          format = 1;
          metadata = buildMetadata;
          service = { inherit name version; };
          dependencies = lib.mapAttrs (_: dependency: dependency.version) (
            builtins.removeAttrs sources [ name ]
          );
        }
      );
      passthru = metadata // {
        inherit version sources requiredPrograms;
      };
    }
  )
  ''
    SC_BUILD_DIR="$NIX_BUILD_TOP/build" SC_OUT_DIR="$out" \
      JOBS="$NIX_BUILD_CORES" bash ${script} ${lib.escapeShellArg version}
  ''
