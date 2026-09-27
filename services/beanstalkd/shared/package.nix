{ sc, version }:
let
  versionDirectory = ../versions + "/${version}";
  versionData = import (versionDirectory + "/version.nix");
  beanstalkdSource = import ./source.nix {
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
  name = "beanstalkd";
  inherit version;
  script = ./build.sh;
  manifest = if builtins.pathExists versionManifest then versionManifest else ./service.toml;
  sources = {
    beanstalkd = beanstalkdSource;
  };
}
