{
  pkgs,
  sc,
  version,
}:
let
  versionDirectory = ../versions + "/${version}";
  versionData = import (versionDirectory + "/version.nix");
  libmariadbSource = import ../deps/libmariadb {
    inherit sc versionDirectory;
    sourceData = versionData.libmariadb;
  };
  wolfsslSource = import ../deps/wolfssl {
    inherit sc versionDirectory;
    sourceData = versionData.wolfssl;
  };
  fmtSource = import ../deps/fmt { inherit sc; };
  pcre2Source = import ../deps/pcre2 { inherit sc; };
  mariadbSource = import ./source.nix {
    inherit
      sc
      version
      versionData
      versionDirectory
      libmariadbSource
      wolfsslSource
      ;
  };
  versionManifest = versionDirectory + "/service.toml";
in
sc.mkGuestBuild {
  name = "mariadb";
  inherit version;
  script = ./build.sh;
  manifest = if builtins.pathExists versionManifest then versionManifest else ./service.toml;
  sources = {
    mariadb = mariadbSource;
    libmariadb = libmariadbSource;
    wolfssl = wolfsslSource;
    fmt = fmtSource;
    pcre2 = pcre2Source;
  };
  nativeBuildInputs = with pkgs; [
    cmakeMinimal
    bison
    wasixRunner
  ];
}
