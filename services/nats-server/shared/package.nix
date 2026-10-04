{ sc, version }:
let
  versionDirectory = ../versions + "/${version}";
  versionData = import (versionDirectory + "/version.nix");
  natsSource = import ./source.nix {
    inherit
      sc
      version
      versionData
      versionDirectory
      ;
  };
  modulesSource = sc.mkSource {
    inherit version;
    key = "go-modules";
    name = "nats-server-${version}-go-modules";
    upstream = sc.fetchGoModules {
      name = "nats-server-${version}-go-modules-vendor";
      tree = natsSource.tree;
      hash = versionData.modules.hash;
    };
    tarHash = versionData.modules.tarHash;
  };
  versionManifest = versionDirectory + "/service.toml";
in
sc.mkGuestBuild {
  name = "nats-server";
  inherit version;
  toolchain = sc.goToolchain;
  script = ./build.sh;
  manifest = if builtins.pathExists versionManifest then versionManifest else ./service.toml;
  sources = {
    nats-server = natsSource;
    go-modules = modulesSource;
  };
}
