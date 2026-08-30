#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../toolchain/lib.sh"
sc_init mysql "${1:?usage: ${BASH_SOURCE[0]} version}"

jobs="${JOBS:-16}"
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
  echo "JOBS must be a positive integer" >&2
  return 1 2>/dev/null || exit 1
fi

case "$OPENSSL_VERSION" in
  3.5.8) openssl_sha256=a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2 ;;
  *) sc_fail "unsupported OpenSSL version: $OPENSSL_VERSION"; return 1 2>/dev/null || exit 1 ;;
esac
# MySQL 8.4 and later bundle Boost; 8.0 pins the release to download.
case "${BOOST_VERSION:-}" in
  "") ;;
  1.77.0) boost_sha256=fc9f85fc030e233142908241af7a846e60630aa7388de9a5fafb1f3a26840854 ;;
  *) sc_fail "unsupported Boost version: $BOOST_VERSION"; return 1 2>/dev/null || exit 1 ;;
esac

MYSQL_DEPS_DIR="$SC_WORK/deps/mysql"
MYSQL_OPENSSL_DIR="$MYSQL_DEPS_DIR/openssl-$OPENSSL_VERSION"
MYSQL_BOOST_DIR="${BOOST_VERSION:+$MYSQL_DEPS_DIR/boost-$BOOST_VERSION}"
export MYSQL_DEPS_DIR MYSQL_OPENSSL_DIR MYSQL_BOOST_DIR

download() {
  local url="$1"
  local destination="$2"
  local sha256="$3"
  local partial="${destination}.part"

  if [[ -f "$destination" ]]; then
    printf '%s  %s\n' "$sha256" "$destination" | sha256sum --check --status ||
      sc_fail "cached download has the wrong checksum: $destination"
    echo "using cached download: ${destination#"$SC_ROOT/"}"
    return
  fi

  echo "downloading: $url"
  curl --fail --location --retry 3 --output "$partial" "$url"
  printf '%s  %s\n' "$sha256" "$partial" | sha256sum --check --status ||
    sc_fail "download checksum failed: $url"
  mv "$partial" "$destination"
}

openssl_ready() {
  local version_header="$MYSQL_OPENSSL_DIR/include/openssl/opensslv.h"
  local config_header="$MYSQL_OPENSSL_DIR/include/openssl/configuration.h"
  local version_major version_minor version_patch
  IFS=. read -r version_major version_minor version_patch <<<"$OPENSSL_VERSION"

  [[ -f "$MYSQL_OPENSSL_DIR/lib/libcrypto.a" ]] || return 1
  [[ -f "$MYSQL_OPENSSL_DIR/lib/libssl.a" ]] || return 1
  [[ -f "$version_header" && -f "$config_header" ]] || return 1
  grep -Eq "^# *define OPENSSL_VERSION_MAJOR +${version_major}$" "$version_header" || return 1
  grep -Eq "^# *define OPENSSL_VERSION_MINOR +${version_minor}$" "$version_header" || return 1
  grep -Eq "^# *define OPENSSL_VERSION_PATCH +${version_patch}$" "$version_header" || return 1
  grep -Eq '^# *define OPENSSL_VERSION_PRE_RELEASE +""$' "$version_header" || return 1
  grep -Eq '^# *define OPENSSL_NO_DGRAM$' "$config_header" || return 1
  "$WASIXCC_DIR/bin/wasixnm" --defined-only --print-file-name \
    "$MYSQL_OPENSSL_DIR/lib/libcrypto.a" 2>/dev/null |
    grep -E 'libcrypto-lib-threads_pthread[.]o: .* T CRYPTO_THREAD_lock_new$' \
      >/dev/null
}

install_openssl() {
  if openssl_ready; then
    echo "OpenSSL $OPENSSL_VERSION WASIX libraries are already installed"
    return
  fi

  local archive="$MYSQL_OPENSSL_DIR/openssl-$OPENSSL_VERSION.tar.gz"
  local source_dir="$MYSQL_OPENSSL_DIR/source"
  local build_dir="$MYSQL_OPENSSL_DIR/build"
  local url="https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"

  mkdir -p "$MYSQL_OPENSSL_DIR"
  download "$url" "$archive" "$openssl_sha256"
  if [[ ! -e "$source_dir" ]]; then
    mkdir -p "$source_dir"
    tar -xzf "$archive" -C "$source_dir" --strip-components=1
  elif [[ ! -f "$source_dir/Configure" ]]; then
    sc_fail "unexpected OpenSSL source directory: $source_dir"
    return 1
  fi

  mkdir -p "$build_dir"
  (
    cd "$build_dir"
    env \
      CC="$WASIXCC_DIR/bin/wasixcc" \
      CXX="$WASIXCC_DIR/bin/wasix++" \
      AR="$WASIXCC_DIR/bin/wasixar" \
      RANLIB="$WASIXCC_DIR/bin/wasixranlib" \
      NM="$WASIXCC_DIR/bin/wasixnm" \
      LD="$WASIXCC_DIR/bin/wasixld" \
      CFLAGS="--target=wasm32-wasix -matomics -mbulk-memory -mmutable-globals -pthread -mthread-model posix -ftls-model=local-exec -fno-trapping-math -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -DUSE_TIMEGM -DOPENSSL_NO_SECURE_MEMORY -DOPENSSL_NO_DGRAM -DOPENSSL_THREADS -O2" \
      LDFLAGS="-Wl,--allow-undefined" \
      "$source_dir/Configure" linux-generic32 \
        --prefix="$MYSQL_OPENSSL_DIR" \
        --libdir=lib \
        -static \
        no-shared \
        no-pic \
        no-asm \
        no-dso \
        no-tests \
        no-apps \
        no-afalgeng \
        no-dgram \
        -DUSE_TIMEGM \
        -DOPENSSL_NO_SECURE_MEMORY \
        -DOPENSSL_NO_DGRAM \
        -DOPENSSL_THREADS
  )

  make -C "$build_dir" -j"$jobs" build_libs
  make -C "$build_dir" install_dev
  openssl_ready || sc_fail "OpenSSL verification failed after installation"
}

install_boost_source() {
  local boost_archive_version="${BOOST_VERSION//./_}"
  local archive="$MYSQL_BOOST_DIR/boost_${boost_archive_version}.tar.bz2"
  local source_dir="$MYSQL_BOOST_DIR/boost_${boost_archive_version}"
  local url="https://archives.boost.io/release/$BOOST_VERSION/source/boost_${boost_archive_version}.tar.bz2"

  mkdir -p "$MYSQL_BOOST_DIR"
  download "$url" "$archive" "$boost_sha256"
  if [[ ! -e "$source_dir" ]]; then
    tar -xjf "$archive" -C "$MYSQL_BOOST_DIR"
  elif [[ ! -f "$source_dir/boost/version.hpp" ]]; then
    sc_fail "unexpected Boost source directory: $source_dir"
    return 1
  fi
  echo "Boost $BOOST_VERSION source is ready"
}

for command_name in curl grep make perl sha256sum tar; do
  command -v "$command_name" >/dev/null 2>&1 ||
    sc_fail "required host command not found: $command_name"
done

install_openssl
if [[ -n "${BOOST_VERSION:-}" ]]; then
  install_boost_source
fi
