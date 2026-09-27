{ pkgs, lib }:
{
  name,
  version,
  upstream,
  tarHash,
  patches ? [ ],
}:
let
  stage = ''
    set -euo pipefail
    staging="$NIX_BUILD_TOP/reduced-source"
    mkdir -p "$staging/source" "$staging/metadata"
    cp -a ${upstream}/. "$staging/source/"
    chmod u+w "$staging/source"
    bash ${./tar.sh} "$staging" "$out"
  '';
  reduction = {
    implementation = stage;
    tarVersion = pkgs.gnutar.version;
    tarSourceHash = pkgs.gnutar.src.outputHash;
  };
  # Fixed-output paths depend on the name and expected hash, not the recipe.
  # Put this fingerprint in the tar name so source or recipe changes cannot
  # silently reuse an old tar when tarHash has not been updated.
  fingerprint = builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toJSON reduction));
  tar = pkgs.stdenvNoCC.mkDerivation {
    name = "${name}-${fingerprint}.tar";
    nativeBuildInputs = [ pkgs.gnutar ];
    phases = [ "buildPhase" ];
    buildPhase = stage;
    outputHashAlgo = "sha256";
    outputHashMode = "flat";
    outputHash = tarHash;
  };
  tree =
    pkgs.runCommand name
      {
        inherit version patches;
        nativeBuildInputs = [
          pkgs.gnutar
          pkgs.gitMinimal
        ];
      }
      ''
        tar -xf ${tar}
        cd source
        for patch in $patches; do
          git apply --whitespace=error-all "$patch"
        done
        cp -r --preserve=mode . "$out"
      '';
in
assert lib.assertMsg (upstream ? scSelection) "mkSource requires a selected upstream source";
{
  inherit
    upstream
    tar
    tree
    version
    ;
}
