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
  loadableModules = [
    {
      name = "plpgsql";
      directory = "src/pl/plpgsql/src";
    }
  ];
  postgresqlSource = import ./source.nix {
    inherit
      pkgs
      sc
      version
      versionData
      versionDirectory
      loadableModules
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
  environment.SC_POSTGRESQL_LOADABLE_MODULES = pkgs.lib.concatMapStringsSep "\n" (
    module: "${module.name} ${module.directory}"
  ) loadableModules;
}
