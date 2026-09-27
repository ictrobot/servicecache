{
  lib,
  sc,
  version,
}:
let
  versionDirectory = ../versions + "/${version}";
  versionData = import (versionDirectory + "/version.nix");
  valkeySource = import ./source.nix {
    inherit
      lib
      sc
      version
      versionData
      versionDirectory
      ;
  };
  versionManifest = versionDirectory + "/service.toml";
in
sc.mkGuestBuild {
  name = "valkey";
  inherit version;
  script = ./build.sh;
  manifest = if builtins.pathExists versionManifest then versionManifest else ./service.toml;
  sources = {
    valkey = valkeySource;
  };
}
