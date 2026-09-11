#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../../toolchain/lib.sh"
sc_init mysql "${1:?usage: $0 version}"
sc_clean_if_toolchain_changed
: "${SC_SOURCE_URL:=https://github.com/mysql/mysql-server.git}"
: "${MYSQL_TAG:=mysql-$SC_VERSION}"
sc_checkout "$SC_SOURCE_URL" "$MYSQL_TAG" "$SC_SRC"
sc_apply_series "$SC_VERSION_DIR/patches" "$SC_SRC"
sc_apply_series "$SC_VERSION_DIR/patches/protobuf" "$SC_SRC"
sc_apply_series "$SC_VERSION_DIR/patches/libmysql" "$SC_SRC"
if [[ -d "$SC_VERSION_DIR/patches/abseil" ]]; then
  sc_apply_series "$SC_VERSION_DIR/patches/abseil" "$SC_SRC"
fi
source "$SC_SERVICE_DIR/deps.sh" "$SC_VERSION"

jobs="${JOBS:-16}"
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
  echo "JOBS must be a positive integer" >&2
  exit 1
fi

# Dependencies, plugins and bundled libraries that differ between MySQL
# release series. 8.0 downloads Boost; 8.4 and 9.x bundle it.
case "$SC_VERSION" in
  8.0.*)
    series_options=(
      -DWITH_BOOST="$MYSQL_BOOST_DIR"
      -DDOWNLOAD_BOOST=OFF
      -DWITH_INNODB_MEMCACHED=OFF
      -DWITH_AUTHENTICATION_FIDO=OFF
      -DWITH_LIBEVENT=bundled
    )
    ;;
  8.4.*|9.*)
    # 8.4 and 9.x are C++20. Upstream injects -std=c++20 through its default
    # compiler options, which this build turns off, and the compile feature
    # MySQL sets on its convenience libraries does not reach their object
    # libraries.
    series_options=(
      -DWITH_AUTHENTICATION_WEBAUTHN=OFF
      -DCMAKE_CXX_STANDARD=20
      -DCMAKE_CXX_EXTENSIONS=OFF
    )
    ;;
  *)
    sc_fail "no CMake options defined for MySQL $SC_VERSION"
    ;;
esac

# MySQL's CMake sniffs the host distribution with `rpm -qf /`; on a .el9
# host that leaks -Wl,--copy-dt-needed-entries into the link options,
# which wasm-ld rejects.
distro_options=(-DMY_RPM=MY_RPM-NOTFOUND)

servicecache_revision="$(git -C "$SC_ROOT" rev-parse --short HEAD)"
cmake -S "$SC_SRC" -B "$SC_BUILD" \
  -G "Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE="$SC_TOOLCHAIN/wasix-toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS_RELEASE="-O1 -DNDEBUG" \
  -DCMAKE_CXX_FLAGS_RELEASE="-O1 -DNDEBUG" \
  -DCMAKE_EXE_LINKER_FLAGS="-pthread -Wl,--no-export-dynamic" \
  -DCMAKE_INSTALL_PREFIX="$SC_BUILD/install" \
  -DTMPDIR=/tmp \
  -DFORCE_UNSUPPORTED_COMPILER=ON \
  "${distro_options[@]}" \
  -DWITH_DEFAULT_COMPILER_OPTIONS=OFF \
  -DWITH_UNIT_TESTS=OFF \
  -DWITH_ROUTER=OFF \
  -DWITH_MYSQLX=OFF \
  -DWITH_NDB=OFF \
  -DWITH_NDBCLUSTER=OFF \
  -DWITH_INNOBASE_STORAGE_ENGINE=ON \
  -DWITH_ARCHIVE_STORAGE_ENGINE=OFF \
  -DWITH_BLACKHOLE_STORAGE_ENGINE=OFF \
  -DWITH_FEDERATED_STORAGE_ENGINE=OFF \
  -DWITH_NDBCLUSTER_STORAGE_ENGINE=OFF \
  -DWITH_AUTHENTICATION_LDAP=OFF \
  -DWITH_AUTHENTICATION_KERBEROS=OFF \
  -DWITH_AUTHENTICATION_CLIENT_PLUGINS=OFF \
  -DWITH_EDITLINE=none \
  -DWITH_TEST_TRACE_PLUGIN=OFF \
  -DWITH_LDAP=none \
  -DWITH_KERBEROS=none \
  -DWITH_SASL=none \
  -DWITH_SSL="$MYSQL_OPENSSL_DIR" \
  -DOPENSSL_ROOT_DIR="$MYSQL_OPENSSL_DIR" \
  -DOPENSSL_INCLUDE_DIR="$MYSQL_OPENSSL_DIR/include" \
  -DOPENSSL_LIBRARY="$MYSQL_OPENSSL_DIR/lib/libssl.a" \
  -DCRYPTO_LIBRARY="$MYSQL_OPENSSL_DIR/lib/libcrypto.a" \
  -DWITH_ZLIB=bundled \
  -DWITH_ZSTD=bundled \
  -DWITH_LZ4=bundled \
  -DWITH_ICU=bundled \
  -DWITH_PROTOBUF=bundled \
  "${series_options[@]}" \
  -DMYSQL_SERVER_SUFFIX=-servicecache \
  -DCOMPILATION_COMMENT_SERVER="WASIX build for ServiceCache, rev $servicecache_revision"

cmake --build "$SC_BUILD" --target mysqld mysql -j"$jobs"

sc_strip "$SC_BUILD/runtime_output_directory/mysqld" "$SC_BUILD/mysqld.wasm"
sc_strip "$SC_BUILD/runtime_output_directory/mysql" "$SC_BUILD/mysql.wasm"

share_dir="$SC_BUILD/assembly/share"
rm -rf "$share_dir"
mkdir -p "$share_dir/english"
cp "$SC_BUILD/share/english/errmsg.sys" "$share_dir/english/errmsg.sys"
cp -a "$SC_SRC/share/charsets" "$share_dir/charsets"

# Run by the prepare step's --init-file, after the bootstrap SQL: an instance
# is disposable, so its redo log is never read back.
printf 'ALTER INSTANCE DISABLE INNODB REDO_LOG;\n' > "$share_dir/servicecache-init.sql"

sc_assemble "$SC_BUILD/mysqld.wasm" "$SC_BUILD/mysql.wasm" "$share_dir"
sc_write_build_info
