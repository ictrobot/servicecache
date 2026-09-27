#!/usr/bin/env bash
set -euo pipefail

source "${SC_TOOLCHAIN:?}/guest-lib.sh"
sc_build_init mariadb "${1:?usage: $0 version}"

# MariaDB's CMake reads Connector/C and wolfSSL from inside its tree, where a
# release carries them as submodules, so the build has a copy of the tree with
# those two sources in their places, and fmt and PCRE2 beside it.
source_dir="$SC_BUILD_DIR/mariadb"
sc_copy_source "$SC_SOURCE_MARIADB_DIR" "$source_dir"
sc_copy_source "$SC_SOURCE_LIBMARIADB_DIR" "$source_dir/libmariadb"
sc_copy_source "$SC_SOURCE_WOLFSSL_DIR" "$source_dir/extra/wolfssl/wolfssl"
sc_copy_source "$SC_SOURCE_FMT_DIR" "$SC_BUILD_DIR/fmt"
sc_copy_source "$SC_SOURCE_PCRE2_DIR" "$SC_BUILD_DIR/pcre2"

guest_build="$SC_BUILD_DIR/guest"

# The patches let CMake take these from trees instead of downloading them.
bundled_options=(
  -DLIBFMT_SOURCE_DIR="$SC_BUILD_DIR/fmt"
  -DPCRE2_SOURCE_DIR="$SC_BUILD_DIR/pcre2"
)
# TLS, in the server and the client, comes from the bundled wolfSSL, which
# its LICENSING offers under GPLv2 when combined with MariaDB Server or its
# client libraries; the patches give Connector/C a wolfSSL backend.
#
# The client verifies a server's certificate only when asked, and does
# without dynamic columns, which neither module uses.
build_options=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_C_FLAGS_RELEASE="-O1 -DNDEBUG"
  -DCMAKE_CXX_FLAGS_RELEASE="-O1 -DNDEBUG"
  -DUPDATE_SUBMODULES=OFF
  -DDISABLE_SHARED=ON
  -DWITHOUT_DYNAMIC_PLUGINS=ON
  -DWITH_UNIT_TESTS=OFF
  -DWITH_EMBEDDED_SERVER=OFF
  -DFEATURE_SET=large
  -DWITH_WSREP=OFF
  -DWITH_SYSTEMD=no
  -DWITH_JEMALLOC=no
  -DWITH_NUMA=OFF
  -DWITH_SAFEMALLOC=OFF
  -DIGNORE_AIO_CHECK=YES
  -DAWS_SDK_EXTERNAL_PROJECT=OFF
  -DWITH_SSL=bundled
  -DCONC_WITH_SSL=WOLFSSL
  -DCONC_DEFAULT_SSL_VERIFY_SERVER_CERT=OFF
  -DCONC_WITH_DYNCOL=OFF
  -DWITH_PCRE=bundled
  -DPLUGIN_AUTH_PAM=NO
  -DPLUGIN_AUTH_SOCKET=NO
  -DPLUGIN_ROCKSDB=NO
  -DPLUGIN_MROONGA=NO
  -DPLUGIN_SPIDER=NO
  -DPLUGIN_CONNECT=NO
  -DPLUGIN_SPHINX=NO
  -DTMPDIR=/tmp
)

# CMake compiles by absolute path, so paths under the build directory are
# mapped to relative ones before they reach the modules. No install prefix:
# the server and the client record their default directories, which are the
# same wherever this runs. The -z relro and -z now that MariaDB's hardening
# asks the linker for are ELF settings wasm-ld lacks, so that check is
# answered.
file_prefix_map="-ffile-prefix-map=$SC_BUILD_DIR/="
sc_guest cmake -S "$source_dir" -B "$guest_build" \
  -G "Unix Makefiles" \
  "${build_options[@]}" \
  "${bundled_options[@]}" \
  -DCMAKE_TOOLCHAIN_FILE="$SC_TOOLCHAIN/guest/toolchain.cmake" \
  -DCMAKE_C_FLAGS="$file_prefix_map" \
  -DCMAKE_CXX_FLAGS="$file_prefix_map" \
  -DCMAKE_EXE_LINKER_FLAGS=-pthread \
  -DHAVE_LINK_FLAG__Wl__z_relro__z_now=0 \
  -DMYSQL_SERVER_SUFFIX=-servicecache \
  -DCOMPILATION_COMMENT="WASIX build for ServiceCache"

sc_guest cmake --build "$guest_build" --target mariadbd mariadb -j"$JOBS"

sc_strip 1 "$guest_build/sql/mariadbd" "$SC_BUILD_DIR/mariadbd.wasm"
sc_strip 1 "$guest_build/client/mariadb" "$SC_BUILD_DIR/mariadb.wasm"

share_dir="$SC_BUILD_DIR/assembly/share"
mkdir -p "$share_dir/english"
cp "$guest_build/sql/share/english/errmsg.sys" "$share_dir/english/errmsg.sys"
cp -r "$source_dir/sql/share/charsets" "$share_dir/charsets"

# The bootstrap input mariadb-install-db would feed the server: the generated
# system-table scripts in its order, without the accounts it creates for the
# host's own name (@current_hostname), which a guest has no use for.
bootstrap_sql="$share_dir/bootstrap.sql"
printf '%s\n' \
  'create database if not exists mysql;' \
  'use mysql;' \
  'SET @auth_root_socket=NULL;' > "$bootstrap_sql"

system_sql_prefix=mysql
if [[ ! -f "$guest_build/scripts/mysql_system_tables.sql" ]]; then
  system_sql_prefix=mariadb
fi
for sql_stem in system_tables performance_tables system_tables_data sys_schema; do
  if [[ ! -f "$guest_build/scripts/${system_sql_prefix}_${sql_stem}.sql" ]]; then
    sc_fail "generated bootstrap SQL not found: ${system_sql_prefix}_${sql_stem}.sql"
  fi
done

for sql_file in \
  "$guest_build/scripts/${system_sql_prefix}_system_tables.sql" \
  "$guest_build/scripts/${system_sql_prefix}_performance_tables.sql" \
  "$guest_build/scripts/${system_sql_prefix}_system_tables_data.sql" \
  "$guest_build/scripts/fill_help_tables.sql" \
  "$guest_build/scripts/maria_add_gis_sp_bootstrap.sql" \
  "$guest_build/scripts/${system_sql_prefix}_sys_schema.sql"; do
  sed '/@current_hostname/d' "$sql_file" >> "$bootstrap_sql"
done

sc_assemble "$SC_BUILD_DIR/mariadbd.wasm" "$SC_BUILD_DIR/mariadb.wasm" "$share_dir"
