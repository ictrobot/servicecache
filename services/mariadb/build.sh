#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../../toolchain/lib.sh"
sc_init mariadb "${1:?usage: $0 version}"
sc_clean_if_toolchain_changed
: "${SC_SOURCE_URL:=https://github.com/MariaDB/server.git}"
: "${MARIADB_TAG:=mariadb-$SC_VERSION}"
sc_checkout "$SC_SOURCE_URL" "$MARIADB_TAG" "$SC_SRC"

# MariaDB's CMake invokes git after the WASIX environment has replaced
# envsubst. Populate only the required submodules with host tools — the
# Connector/C client library and the bundled wolfSSL — then keep CMake from
# updating unrelated optional submodules.
env PATH=/usr/bin:/bin git -C "$SC_SRC" submodule update --init --depth 1 libmariadb extra/wolfssl/wolfssl

sc_apply_series "$SC_VERSION_DIR/patches" "$SC_SRC"
# The connector series applies at the commit the release pins.
mariadb_tag="$SC_UPSTREAM_TAG"
SC_UPSTREAM_TAG="$(git -C "$SC_SRC" rev-parse HEAD:libmariadb)"
sc_apply_series "$SC_VERSION_DIR/patches/libmariadb" "$SC_SRC/libmariadb"
SC_UPSTREAM_TAG="$mariadb_tag"
export SC_UPSTREAM_TAG

jobs="${JOBS:-16}"
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
  echo "JOBS must be a positive integer" >&2
  exit 1
fi

# TLS, in the server and the client, comes from the bundled wolfSSL, which
# its LICENSING offers under GPLv2 when combined with MariaDB Server or its
# client libraries; the patches give Connector/C a wolfSSL backend.
servicecache_revision="$(git -C "$SC_ROOT" rev-parse --short HEAD)"
cmake -S "$SC_SRC" -B "$SC_BUILD" \
  -G "Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE="$SC_TOOLCHAIN/wasix-toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS_RELEASE="-O1 -DNDEBUG" \
  -DCMAKE_CXX_FLAGS_RELEASE="-O1 -DNDEBUG" \
  -DCMAKE_EXE_LINKER_FLAGS="-pthread -Wl,--no-export-dynamic" \
  -DCMAKE_INSTALL_PREFIX="$SC_BUILD/install" \
  -DUPDATE_SUBMODULES=OFF \
  -DDISABLE_SHARED=ON \
  -DWITHOUT_DYNAMIC_PLUGINS=ON \
  -DWITH_UNIT_TESTS=OFF \
  -DWITH_EMBEDDED_SERVER=OFF \
  -DFEATURE_SET=large \
  -DWITH_WSREP=OFF \
  -DWITH_SYSTEMD=no \
  -DWITH_JEMALLOC=no \
  -DWITH_NUMA=OFF \
  -DWITH_SAFEMALLOC=OFF \
  -DIGNORE_AIO_CHECK=YES \
  -DAWS_SDK_EXTERNAL_PROJECT=OFF \
  -DWITH_SSL=bundled \
  -DCONC_WITH_SSL=WOLFSSL \
  -DWITH_PCRE=bundled \
  -DPLUGIN_AUTH_PAM=NO \
  -DPLUGIN_AUTH_SOCKET=NO \
  -DPLUGIN_ROCKSDB=NO \
  -DPLUGIN_MROONGA=NO \
  -DPLUGIN_SPIDER=NO \
  -DPLUGIN_CONNECT=NO \
  -DPLUGIN_SPHINX=NO \
  -DMYSQL_SERVER_SUFFIX=-servicecache \
  -DCOMPILATION_COMMENT="WASIX build for ServiceCache, rev $servicecache_revision" \
  -DTMPDIR=/tmp

cmake --build "$SC_BUILD" --target mariadbd mariadb -j"$jobs"

sc_strip "$SC_BUILD/sql/mariadbd" "$SC_BUILD/mariadbd.wasm"
sc_strip "$SC_BUILD/client/mariadb" "$SC_BUILD/mariadb.wasm"

share_dir="$SC_BUILD/assembly/share"
rm -rf "$share_dir"
mkdir -p "$share_dir/english"
cp "$SC_BUILD/sql/share/english/errmsg.sys" "$share_dir/english/errmsg.sys"
cp -a "$SC_SRC/sql/share/charsets" "$share_dir/charsets"

# The bootstrap input mariadb-install-db would feed the server: the generated
# system-table scripts in its order, without the accounts it creates for the
# host's own name (@current_hostname), which a guest has no use for.
bootstrap_sql="$share_dir/bootstrap.sql"
printf '%s\n' \
  'create database if not exists mysql;' \
  'use mysql;' \
  'SET @auth_root_socket=NULL;' > "$bootstrap_sql"

system_sql_prefix=mysql
if [[ ! -f "$SC_BUILD/scripts/mysql_system_tables.sql" ]]; then
  system_sql_prefix=mariadb
fi
for sql_stem in system_tables performance_tables system_tables_data sys_schema; do
  if [[ ! -f "$SC_BUILD/scripts/${system_sql_prefix}_${sql_stem}.sql" ]]; then
    sc_fail "generated bootstrap SQL not found: ${system_sql_prefix}_${sql_stem}.sql"
  fi
done

for sql_file in \
  "$SC_BUILD/scripts/${system_sql_prefix}_system_tables.sql" \
  "$SC_BUILD/scripts/${system_sql_prefix}_performance_tables.sql" \
  "$SC_BUILD/scripts/${system_sql_prefix}_system_tables_data.sql" \
  "$SC_BUILD/scripts/fill_help_tables.sql" \
  "$SC_BUILD/scripts/maria_add_gis_sp_bootstrap.sql" \
  "$SC_BUILD/scripts/${system_sql_prefix}_sys_schema.sql"; do
  sed '/@current_hostname/d' "$sql_file" >> "$bootstrap_sql"
done

sc_assemble "$SC_BUILD/mariadbd.wasm" "$SC_BUILD/mariadb.wasm" "$share_dir"
sc_write_build_info
