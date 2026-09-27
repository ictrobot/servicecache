# Build programs available to service, library and extension declarations.
{ pkgs }:
{
  inherit (pkgs)
    bison
    flex
    perl
    python3Minimal
    runCommand
    ;

  wasixRunner = pkgs.writeShellScriptBin "wasix-runner" ''
    set -eu
    module="''${1:?usage: wasix-runner module [arguments...]}"
    shift

    # Wasmer refuses the build directory as --cwd when only TMPDIR above it
    # is mounted ("Could not check specified current directory: invalid
    # input"), so it is mounted on its own as well.
    exec ${pkgs.wasmer}/bin/wasmer run \
      --cranelift --compiler-threads 1 --offline \
      --wasmer-dir "''${TMPDIR:?}/wasmer" \
      --cache-dir "$TMPDIR/wasmer/cache" \
      --volume "$TMPDIR:$TMPDIR" \
      --volume "''${SC_BUILD_DIR:?}:$SC_BUILD_DIR" \
      --volume "${builtins.storeDir}:${builtins.storeDir}" \
      --cwd "$PWD" \
      "$module" -- "$@"
  '';

  lib = {
    inherit (pkgs.lib) optional;
    fileset = {
      inherit (pkgs.lib.fileset) toSource unions;
    };
  };
}
