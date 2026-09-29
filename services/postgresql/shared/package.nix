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
  contrib = name: {
    inherit name;
    directory = "contrib/${name}";
  };
  loadableModules = [
    {
      name = "plpgsql";
      directory = "src/pl/plpgsql/src";
    }
    (contrib "bloom")
    (contrib "btree_gin")
    (contrib "btree_gist")
    (contrib "citext")
    (contrib "cube")
    (contrib "dict_int")
    (contrib "earthdistance")
    (contrib "hstore")
    # intarray's library is _int.
    {
      name = "_int";
      directory = "contrib/intarray";
    }
    (contrib "isn")
    (contrib "lo")
    (contrib "ltree")
    (contrib "pg_trgm")
    (contrib "pgcrypto")
    (contrib "seg")
    (contrib "sslinfo")
    (contrib "tablefunc")
    (contrib "tcn")
    (contrib "tsm_system_rows")
    (contrib "tsm_system_time")
    (contrib "unaccent")
    (contrib "uuid-ossp")
    # contrib/spi builds four trigger modules; only moddatetime is linked in.
    {
      name = "moddatetime";
      directory = "contrib/spi";
      makeFlags = [
        "MODULES=moddatetime"
        "EXTENSION=moddatetime"
        "DATA=moddatetime--1.0.sql"
      ];
    }
    # pgvector's makefile is written for PGXS, so it is pointed at this build
    # tree instead of an installed server; an empty OPTFLAGS leaves out the
    # -march=native it would add.
    {
      name = "vector";
      directory = "pgvector";
      makeFlags = [
        "PG_CONFIG=true"
        "PGXS=../src/makefiles/pgxs.mk"
        "includedir_server=../src/include"
        "includedir_internal=../src/include"
        "OPTFLAGS="
      ];
      # Parallel index builds start their workers by these names.
      entryPoints = [
        "HnswParallelBuildMain"
        "IvfflatParallelBuildMain"
      ];
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
  pgvectorSource = import ../deps/pgvector { inherit sc; };
  versionManifest = versionDirectory + "/service.toml";
in
sc.mkGuestBuild {
  name = "postgresql";
  inherit version;
  script = ./build.sh;
  manifest = if builtins.pathExists versionManifest then versionManifest else ./service.toml;
  sources = {
    postgresql = postgresqlSource;
    pgvector = pgvectorSource;
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
    module: "${module.name} ${module.directory} ${toString (module.makeFlags or [ ])}"
  ) loadableModules;
  environment.SC_POSTGRESQL_MODULE_ENTRY_POINTS = pkgs.lib.concatMapStringsSep "\n" (
    module: "${module.name} ${toString module.entryPoints}"
  ) (builtins.filter (module: module ? entryPoints) loadableModules);
}
