# A source tar's build, imported from its servicecache/nix directory: ../.. is
# the source tar's root, with the manifest, flake lock and upstream source tars.
{ nixpkgs, system }:
let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.${system};
  manifest = builtins.fromJSON (builtins.readFile ../../manifest.json);
  lock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  nixpkgsNode = lock.nodes.${lock.root}.inputs.nixpkgs;
  lockedNixpkgs = lock.nodes.${nixpkgsNode}.locked;
  validSourceFile =
    file: builtins.isString file && builtins.match "[A-Za-z0-9][A-Za-z0-9._+-]*[.]tar" file != null;
  validHash = hash: builtins.isString hash && builtins.match "[0-9a-f]{64}" hash != null;
  validSource =
    name: entry:
    builtins.match "[A-Za-z0-9][A-Za-z0-9._+-]*" name != null
    && builtins.isAttrs entry
    && validSourceFile (entry.file or null)
    && validHash (entry.sha256 or null);
  importSourceTar =
    file: sha256:
    let
      # A path value avoids inheriting the containing derivation's store references.
      path = ../../sources + "/${file}";
    in
    assert lib.assertMsg (builtins.pathExists path) "Source tar: missing ${file}";
    # builtins.path can reuse an existing store path without checking this file.
    # Verify the embedded tar even when the correct source is already cached.
    assert lib.assertMsg (
      builtins.hashFile "sha256" path == sha256
    ) "Source tar: incorrect hash for ${file}";
    builtins.path {
      inherit path sha256;
      name = file;
      recursive = false;
    };
  packages = import ./collect-services.nix {
    inherit pkgs;
    buildMetadata.nixpkgsRevision = lockedNixpkgs.rev;
  };
  service = packages.services.${manifest.service};
  expectedUpstreamSources = lib.mapAttrs (_: source: source.metadata) service.upstreamSources;
  declaredUpstreamSources = manifest.upstreamSources;
  importedUpstreamSources = lib.mapAttrs (
    _: entry: importSourceTar entry.file entry.sha256
  ) declaredUpstreamSources;
  requiredPrograms = lib.unique (
    [ pkgs.stdenvNoCC ] ++ pkgs.stdenvNoCC.initialPath ++ service.requiredPrograms
  );
  prepare = pkgs.runCommand "${manifest.service}-prepare" { } ''
    mkdir -p "$out/programs"
    ln -s ${nixpkgs.outPath} "$out/nixpkgs"
    ${lib.concatStringsSep "\n" (
      lib.imap0 (
        index: program: ''ln -s ${program} "$out/programs/${toString index}-${program.name}"''
      ) requiredPrograms
    )}
  '';
in
assert lib.assertMsg (manifest.format == 1) "Source tar: unsupported format";
assert lib.assertMsg (
  builtins.isString manifest.service
  && builtins.match "[A-Za-z0-9][A-Za-z0-9._+-]*" manifest.service != null
) "Source tar: invalid service name";
assert lib.assertMsg (
  builtins.isAttrs declaredUpstreamSources
  && lib.all (name: validSource name declaredUpstreamSources.${name}) (
    builtins.attrNames declaredUpstreamSources
  )
) "Source tar: invalid source identities";
assert lib.assertMsg (
  nixpkgs.narHash == lockedNixpkgs.narHash && (!(nixpkgs ? rev) || nixpkgs.rev == lockedNixpkgs.rev)
) "Source tar: nixpkgs differs from its lock";
assert lib.assertMsg (
  expectedUpstreamSources == declaredUpstreamSources
) "Source tar: upstream sources differ from the ServiceCache source";
{
  inherit prepare;
  default = builtins.deepSeq importedUpstreamSources service;
  ${manifest.service} = builtins.deepSeq importedUpstreamSources service;
}
