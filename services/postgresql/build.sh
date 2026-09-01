#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../../toolchain/lib.sh"
sc_init postgresql "${1:?usage: $0 version}"
: "${SC_SOURCE_URL:=https://github.com/postgres/postgres.git}"
: "${POSTGRESQL_TAG:=REL_${SC_VERSION//./_}}"
sc_checkout "$SC_SOURCE_URL" "$POSTGRESQL_TAG" "$SC_SRC"
sc_apply_series "$SC_VERSION_DIR/patches" "$SC_SRC"

for tool in perl bison flex zic; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "required host command not found: $tool" >&2
    exit 1
  }
done

jobs="${JOBS:-16}"
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
  echo "JOBS must be a positive integer" >&2
  exit 1
fi

mkdir -p "$SC_BUILD"

# The patch series adds this shim; force-including it into every translation
# unit is what makes the port's sig_atomic_t flags WebAssembly atomics.
atomic_sigatomic_header="$SC_SRC/src/include/port/wasix_atomic_sigatomic.h"

# EXEC_BACKEND launches a fresh module for each postmaster child, avoiding the
# unavailable fork() symbol and using the exception-enabled sysroot.
export WASIXCC_AUTOCONF_WORKAROUNDS=yes
export WASIXCC_GENERATE_SHELL_SCRIPT=no

configure_args=(
  --host=wasm32-wasix
  --with-template=linux
  --prefix="$SC_BUILD/install"
  --disable-rpath
  --disable-nls
  --without-icu
  --without-libxml
  --without-libxslt
  --without-llvm
  --without-lz4
  --without-zstd
  --without-readline
  --without-zlib
)

(
  cd "$SC_BUILD"
  env \
    CC="$WASIXCC_DIR/bin/wasixcc" \
    AR="$WASIXCC_DIR/bin/wasixar" \
    RANLIB="$WASIXCC_DIR/bin/wasixranlib" \
    CPPFLAGS="-I$SC_ROOT/extensions/ictrobot_shm_v1 -include $atomic_sigatomic_header" \
    CFLAGS="-O1 -DNDEBUG -DEXEC_BACKEND -pthread" \
    LDFLAGS="-pthread -Wl,--no-export-dynamic" \
    "$SC_SRC/configure" "${configure_args[@]}"
)

# Entering the backend subdirectory directly otherwise races generated catalog
# and error-code headers against parallel compilation.
make -C "$SC_BUILD/src/backend" generated-headers
# Several backend prerequisites recurse into src/port; generate this shared
# header once before those parallel submakes can race while writing it.
make -C "$SC_BUILD/src/port" pg_config_paths.h
make -C "$SC_BUILD/src/port" -j"$jobs" all
make -C "$SC_BUILD/src/common" -j"$jobs" all
make -C "$SC_BUILD/src/backend" -j"$jobs" all
make -C "$SC_BUILD/src/backend/snowball" snowball_create.sql
make -C "$SC_BUILD/src/bin/initdb" -j"$jobs" all
make -C "$SC_BUILD/src/bin/psql" -j"$jobs" all

sc_strip "$SC_BUILD/src/backend/postgres" "$SC_BUILD/postgres.wasm"
sc_strip "$SC_BUILD/src/bin/initdb/initdb" "$SC_BUILD/initdb.wasm"
sc_strip "$SC_BUILD/src/bin/psql/psql" "$SC_BUILD/psql.wasm"

# initdb locates and executes a sibling named exactly "postgres" while it
# bootstraps the catalogs. WASIX can spawn a WebAssembly module by path, so
# link the server module under that expected name too.
ln -sfn postgres.wasm "$SC_BUILD/postgres"

share_dir="$SC_BUILD/assembly/share"
rm -rf "$share_dir"
mkdir -p "$share_dir/timezone" "$share_dir/timezonesets"
cp "$SC_BUILD/src/include/catalog/postgres.bki" "$share_dir/postgres.bki"
cp "$SC_BUILD/src/include/catalog/system_constraints.sql" "$share_dir/system_constraints.sql"
cp "$SC_SRC/src/backend/catalog/system_functions.sql" "$share_dir/system_functions.sql"
cp "$SC_SRC/src/backend/catalog/system_views.sql" "$share_dir/system_views.sql"
cp "$SC_SRC/src/backend/catalog/information_schema.sql" "$share_dir/information_schema.sql"
cp "$SC_SRC/src/backend/catalog/sql_features.txt" "$share_dir/sql_features.txt"
cp "$SC_BUILD/src/backend/snowball/snowball_create.sql" "$share_dir/snowball_create.sql"
cp "$SC_SRC/src/backend/libpq/pg_hba.conf.sample" "$share_dir/pg_hba.conf.sample"
cp "$SC_SRC/src/backend/libpq/pg_ident.conf.sample" "$share_dir/pg_ident.conf.sample"
cp "$SC_SRC/src/backend/utils/misc/postgresql.conf.sample" "$share_dir/postgresql.conf.sample"
cp "$SC_SRC/src/timezone/tznames/"*.txt "$share_dir/timezonesets/"
cp "$SC_SRC/src/timezone/tznames/Default" "$share_dir/timezonesets/Default"
cp "$SC_SRC/src/timezone/tznames/Australia" "$share_dir/timezonesets/Australia"
cp "$SC_SRC/src/timezone/tznames/India" "$share_dir/timezonesets/India"
zic -d "$share_dir/timezone" "$SC_SRC/src/timezone/data/tzdata.zi"

sc_assemble "$SC_BUILD/postgres.wasm" "$SC_BUILD/postgres" "$SC_BUILD/initdb.wasm" \
  "$SC_BUILD/psql.wasm" "$share_dir"
sc_write_build_info
