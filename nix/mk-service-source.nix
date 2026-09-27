{ pkgs, lib }:
{
  service,
  serviceName,
  servicecacheFiles,
  flakeFile,
}:
let
  servicecacheSource = import ./servicecache-source.nix { inherit pkgs lib; } (
    servicecacheFiles // service.servicecacheFiles
  );
  declaration = builtins.toFile "source-manifest.json" (
    builtins.toJSON {
      format = 1;
      service = serviceName;
      upstreamSources = lib.mapAttrs (_: source: source.metadata) service.upstreamSources;
    }
  );
  directory = pkgs.runCommand "${serviceName}-source" { nativeBuildInputs = [ pkgs.jq ]; } ''
    mkdir -p "$out/sources"
    # Evaluation reads this directory, and Nix does not read through a link.
    cp -r ${servicecacheSource} "$out/servicecache"
    jq . ${declaration} > "$out/manifest.json"
    ${lib.concatMapStringsSep "\n" (
      tar: "ln -s ${tar} \"$out/sources/\"${lib.escapeShellArg tar.name}"
    ) (lib.unique (map (source: source.tar) (builtins.attrValues service.upstreamSources)))}
    cp ${flakeFile} "$out/flake.nix"
    cp ${servicecacheSource}/flake.lock "$out/flake.lock"
    cp ${servicecacheSource}/nix/build.sh "$out/build.sh"
  '';
  tar =
    pkgs.runCommand "${serviceName}-source.tar.zst"
      {
        nativeBuildInputs = [
          pkgs.gnutar
          pkgs.zstd
        ];
      }
      ''
        # The directory shares tars through symlinks; the archive embeds their bytes.
        TAR_OPTIONS=--dereference bash ${./tar.sh} ${directory} "$out" zstd
      '';
in
{
  inherit directory tar;
}
