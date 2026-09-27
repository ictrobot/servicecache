{
  pkgs,
  sc,
  version,
  libraries,
}:
let
  versionDirectory = ../versions + "/${version}";
  versionData = import (versionDirectory + "/version.nix");
  boostSource = import ../deps/boost { inherit sc; };
  mysqlSource = import ./source.nix {
    inherit
      pkgs
      sc
      version
      versionData
      versionDirectory
      ;
  };
  versionManifest = versionDirectory + "/service.toml";
in
sc.mkGuestBuild {
  name = "mysql";
  inherit version;
  script = ./build.sh;
  manifest = if builtins.pathExists versionManifest then versionManifest else ./service.toml;
  sources = {
    mysql = mysqlSource;
  }
  // pkgs.lib.optionalAttrs (pkgs.lib.hasPrefix "8.0." version) { boost = boostSource; };
  nativeBuildInputs = with pkgs; [
    cmakeMinimal
    bison
    wasixRunner
  ];
  libraries = { inherit (libraries) openssl; };
}
