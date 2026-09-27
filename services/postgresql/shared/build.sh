#!/usr/bin/env bash
set -euo pipefail

source "${SC_TOOLCHAIN:?}/guest-lib.sh"
sc_build_init postgresql "${1:?usage: $0 version}"

# Built inside a copy of the sources, so that the source paths the modules
# record are files' places in PostgreSQL rather than paths of this build.
build="$SC_BUILD_DIR/postgresql"
sc_copy_source "$SC_SOURCE_POSTGRESQL_DIR" "$build"

# The patch series adds this shim; force-including it into every translation
# unit is what makes the port's sig_atomic_t flags WebAssembly atomics.
atomic_sigatomic_header="$SC_SOURCE_POSTGRESQL_DIR/src/include/port/wasix_atomic_sigatomic.h"

# OpenSSL is the one library the server is configured against: it gives the
# backend and libpq their TLS code, and SCRAM and the SHA and HMAC functions
# libcrypto's implementations rather than the copies src/common carries for
# builds without one.
#
# No --prefix: nothing is installed, and the server records the configured
# directories. The default is the same wherever this runs, which a directory
# of the build is not, and share/ is found beside the module either way.
configure_args=(
  --host=wasm32-wasix
  --with-template=linux
  --disable-rpath
  --disable-nls
  --with-ssl=openssl
  --with-includes="$SC_LIBRARY_OPENSSL_DIR/include"
  --with-libraries="$SC_LIBRARY_OPENSSL_DIR/lib"
  --without-icu
  --without-libxml
  --without-libxslt
  --without-llvm
  --without-lz4
  --without-zstd
  --without-readline
  --without-zlib
)

# EXEC_BACKEND launches a fresh module for each postmaster child: the C
# library declares no fork() for a guest built with WebAssembly exceptions.
# CONFIG_SHELL keeps configure, and the config.status it writes, on the shell
# Nix supplies rather than the machine's /bin/sh.
(
  cd "$build"
  sc_guest env \
    CONFIG_SHELL="$BASH" \
    ZIC="wasix-runner $build/src/timezone/zic" \
    CC="${SC_CCACHE:+$SC_CCACHE }guest-cc" \
    AR=guest-ar \
    RANLIB=guest-ranlib \
    CPPFLAGS="-I$SC_EXTENSION_ICTROBOT_SHM_V1_DIR -include $atomic_sigatomic_header" \
    CFLAGS="-O1 -DNDEBUG -DEXEC_BACKEND -pthread" \
    LDFLAGS=-pthread \
    "$BASH" ./configure "${configure_args[@]}"
)

# Entering the backend subdirectory directly otherwise races generated catalog
# and error-code headers against parallel compilation.
sc_guest make -C "$build/src/backend" generated-headers
# Several backend prerequisites recurse into src/port; generate this shared
# header once before those parallel submakes can race while writing it.
sc_guest make -C "$build/src/port" pg_config_paths.h
sc_guest make -C "$build/src/port" -j"$JOBS" all
sc_guest make -C "$build/src/common" -j"$JOBS" all
sc_guest make -C "$build/src/backend" -j"$JOBS" all
sc_guest make -C "$build/src/backend/snowball" snowball_create.sql
sc_guest make -C "$build/src/bin/initdb" -j"$JOBS" all
sc_guest make -C "$build/src/bin/psql" -j"$JOBS" all

sc_strip 1 "$build/src/backend/postgres" "$SC_BUILD_DIR/postgres.wasm"
sc_strip 1 "$build/src/bin/initdb/initdb" "$SC_BUILD_DIR/initdb.wasm"
sc_strip 1 "$build/src/bin/psql/psql" "$SC_BUILD_DIR/psql.wasm"

# initdb locates and executes a sibling named exactly "postgres" while it
# bootstraps the catalogs. WASIX can spawn a WebAssembly module by path, so
# link the server module under that expected name too.
ln -sfn postgres.wasm "$SC_BUILD_DIR/postgres"

share_dir="$SC_BUILD_DIR/assembly/share"
mkdir -p "$share_dir/timezone" "$share_dir/timezonesets"
cp "$build/src/include/catalog/postgres.bki" "$share_dir/postgres.bki"
cp "$build/src/include/catalog/system_constraints.sql" "$share_dir/system_constraints.sql"
cp "$build/src/backend/catalog/system_functions.sql" "$share_dir/system_functions.sql"
cp "$build/src/backend/catalog/system_views.sql" "$share_dir/system_views.sql"
cp "$build/src/backend/catalog/information_schema.sql" "$share_dir/information_schema.sql"
cp "$build/src/backend/catalog/sql_features.txt" "$share_dir/sql_features.txt"
cp "$build/src/backend/snowball/snowball_create.sql" "$share_dir/snowball_create.sql"
cp "$build/src/backend/libpq/pg_hba.conf.sample" "$share_dir/pg_hba.conf.sample"
cp "$build/src/backend/libpq/pg_ident.conf.sample" "$share_dir/pg_ident.conf.sample"
cp "$build/src/backend/utils/misc/postgresql.conf.sample" "$share_dir/postgresql.conf.sample"
cp "$build/src/timezone/tznames/"*.txt "$share_dir/timezonesets/"
cp "$build/src/timezone/tznames/Default" "$share_dir/timezonesets/Default"
cp "$build/src/timezone/tznames/Australia" "$share_dir/timezonesets/Australia"
cp "$build/src/timezone/tznames/India" "$share_dir/timezonesets/India"
sc_guest make -C "$build/src/timezone" -j"$JOBS" zic
wasix-runner "$build/src/timezone/zic" -d "$share_dir/timezone" "$build/src/timezone/data/tzdata.zi"

sc_assemble "$SC_BUILD_DIR/postgres.wasm" "$SC_BUILD_DIR/postgres" "$SC_BUILD_DIR/initdb.wasm" \
  "$SC_BUILD_DIR/psql.wasm" "$share_dir"
