#!/usr/bin/env bash
set -euo pipefail

source "${SC_TOOLCHAIN:?}/guest-lib.sh"
sc_build_init mysql "${1:?usage: $0 version}"

# Built inside a copy of the tree.
source_dir="$SC_BUILD_DIR/mysql"
sc_copy_source "$SC_SOURCE_MYSQL_DIR" "$source_dir"

guest_build="$SC_BUILD_DIR/guest"

# Dependencies, plugins and bundled libraries that differ between MySQL
# release series. 8.0 is built against Boost, a source of its own; 8.4 and
# 9.x bundle it.
case "$SC_VERSION" in
  8.0.*)
    sc_copy_source "$SC_SOURCE_BOOST_DIR" "$SC_BUILD_DIR/boost"
    series_options=(
      -DWITH_BOOST="$SC_BUILD_DIR/boost"
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

# MySQL's CMake asks rpm which distribution it is on and, from some answers,
# adds a link option wasm-ld rejects; MY_RPM says rpm is not there.
build_options=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_C_FLAGS_RELEASE="-O1 -DNDEBUG"
  -DCMAKE_CXX_FLAGS_RELEASE="-O1 -DNDEBUG"
  -DFORCE_UNSUPPORTED_COMPILER=ON
  -DMY_RPM=MY_RPM-NOTFOUND
  -DWITH_DEFAULT_COMPILER_OPTIONS=OFF
  -DWITH_UNIT_TESTS=OFF
  -DWITH_ROUTER=OFF
  -DWITH_MYSQLX=OFF
  -DWITH_NDB=OFF
  -DWITH_NDBCLUSTER=OFF
  -DWITH_ARCHIVE_STORAGE_ENGINE=OFF
  -DWITH_BLACKHOLE_STORAGE_ENGINE=OFF
  -DWITH_FEDERATED_STORAGE_ENGINE=OFF
  -DWITH_NDBCLUSTER_STORAGE_ENGINE=OFF
  -DWITH_AUTHENTICATION_LDAP=OFF
  -DWITH_AUTHENTICATION_KERBEROS=OFF
  -DWITH_AUTHENTICATION_CLIENT_PLUGINS=OFF
  -DWITH_EDITLINE=none
  -DWITH_TEST_TRACE_PLUGIN=OFF
  -DWITH_LDAP=none
  -DWITH_KERBEROS=none
  -DWITH_SASL=none
  -DWITH_ZLIB=bundled
  -DWITH_ZSTD=bundled
  -DWITH_LZ4=bundled
  -DWITH_ICU=bundled
  -DWITH_PROTOBUF=bundled
)

# CMake compiles by absolute path, so paths under the build directory are
# mapped to relative ones before they reach the modules. No install prefix:
# the server and the client record their default directories, which are the
# same wherever this runs.
file_prefix_map="-ffile-prefix-map=$SC_BUILD_DIR/="
sc_guest cmake -S "$source_dir" -B "$guest_build" \
  -G "Unix Makefiles" \
  "${build_options[@]}" \
  "${series_options[@]}" \
  -DCMAKE_TOOLCHAIN_FILE="$SC_TOOLCHAIN/guest/toolchain.cmake" \
  -DCMAKE_C_FLAGS="$file_prefix_map" \
  -DCMAKE_CXX_FLAGS="$file_prefix_map" \
  -DCMAKE_EXE_LINKER_FLAGS=-pthread \
  -DTMPDIR=/tmp \
  -DWITH_INNOBASE_STORAGE_ENGINE=ON \
  -DWITH_SSL="$SC_LIBRARY_OPENSSL_DIR" \
  -DOPENSSL_ROOT_DIR="$SC_LIBRARY_OPENSSL_DIR" \
  -DOPENSSL_INCLUDE_DIR="$SC_LIBRARY_OPENSSL_DIR/include" \
  -DOPENSSL_LIBRARY="$SC_LIBRARY_OPENSSL_DIR/lib/libssl.a" \
  -DCRYPTO_LIBRARY="$SC_LIBRARY_OPENSSL_DIR/lib/libcrypto.a" \
  -DMYSQL_SERVER_SUFFIX=-servicecache \
  -DCOMPILATION_COMMENT_SERVER="WASIX build for ServiceCache"

sc_guest cmake --build "$guest_build" --target mysqld mysql -j"$JOBS"

sc_strip 1 "$guest_build/runtime_output_directory/mysqld" "$SC_BUILD_DIR/mysqld.wasm"
sc_strip 1 "$guest_build/runtime_output_directory/mysql" "$SC_BUILD_DIR/mysql.wasm"

share_dir="$SC_BUILD_DIR/assembly/share"
mkdir -p "$share_dir/english"
cp "$guest_build/share/english/errmsg.sys" "$share_dir/english/errmsg.sys"
cp -r "$source_dir/share/charsets" "$share_dir/charsets"

# Run by the prepare step's --init-file, after the bootstrap SQL: an instance
# is disposable, so its redo log is never read back.
printf 'ALTER INSTANCE DISABLE INNODB REDO_LOG;\n' > "$share_dir/servicecache-init.sql"

sc_assemble "$SC_BUILD_DIR/mysqld.wasm" "$SC_BUILD_DIR/mysql.wasm" "$share_dir"
