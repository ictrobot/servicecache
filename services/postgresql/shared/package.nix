{
  pkgs,
  sc,
  version,
  libraries,
  extensions,
}:
let
  versionDirectory = ../versions + "/${version}";
  versionData = import (versionDirectory + "/version.nix");
  postgresqlSource = import ./source.nix {
    inherit
      sc
      version
      versionData
      versionDirectory
      ;
  };
  versionManifest = versionDirectory + "/service.toml";
in
sc.mkGuestBuild {
  name = "postgresql";
  inherit version;
  script = ./build.sh;
  manifest = if builtins.pathExists versionManifest then versionManifest else ./service.toml;
  sources = {
    postgresql = postgresqlSource;
  };
  nativeBuildInputs = with pkgs; [
    perl
    bison
    flex
    wasixRunner
  ];
  libraries = { inherit (libraries) openssl; };
  extensions = { inherit (extensions) ictrobot_shm_v1; };
}
