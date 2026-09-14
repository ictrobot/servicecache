#!/usr/bin/env bash
set -euo pipefail

# The WASIX build of OpenSSL: the static libcrypto and libssl a service links
# against to speak TLS, and the headers it compiles against.
#
#   toolchain/libs/openssl/build.sh version
#
# builds that version into $(sc_lib_dir openssl version), leaving its lib and
# include directories ready for a service's build system, and does nothing
# when a complete build is already there. The archive, the unpacked source and
# the build tree live in that directory too, so removing it removes the whole
# build.

# Services run this through a link in their libs directory, so find the
# repository from where the script really is.
SC_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
source "$SC_ROOT/toolchain/lib.sh"
source "$SC_ROOT/toolchain/versions.sh"
source "$SC_ROOT/toolchain/env.sh"

if [[ $# -ne 1 ]]; then
  echo "usage: $0 version" >&2
  exit 2
fi
version="$1"

# The checksum of each supported release tarball, as published by OpenSSL.
case "$version" in
  3.5.8) sha256=a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2 ;;
  *) sc_fail "unsupported OpenSSL version: $version"; exit 1 ;;
esac
install_dir="$(sc_lib_dir openssl "$version")"

jobs="${JOBS:-16}"
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
  sc_fail "JOBS must be a positive integer"
  exit 1
fi
for command_name in curl grep make perl sha256sum tar; do
  command -v "$command_name" >/dev/null 2>&1 ||
    { sc_fail "required host command not found: $command_name"; exit 1; }
done

# Whether the directory already holds a complete WASIX build of this version of
# OpenSSL: both static libraries, headers that announce the version asked for,
# the datagram support this target does without, and real pthread locking
# rather than the no-op the configuration falls back to when it decides the
# platform has no threads.
openssl_ready() {
  local version_header="$install_dir/include/openssl/opensslv.h"
  local config_header="$install_dir/include/openssl/configuration.h"
  local version_major version_minor version_patch
  IFS=. read -r version_major version_minor version_patch <<<"$version"

  [[ -f "$install_dir/lib/libcrypto.a" ]] || return 1
  [[ -f "$install_dir/lib/libssl.a" ]] || return 1
  [[ -f "$version_header" && -f "$config_header" ]] || return 1
  grep -Eq "^# *define OPENSSL_VERSION_MAJOR +${version_major}$" "$version_header" || return 1
  grep -Eq "^# *define OPENSSL_VERSION_MINOR +${version_minor}$" "$version_header" || return 1
  grep -Eq "^# *define OPENSSL_VERSION_PATCH +${version_patch}$" "$version_header" || return 1
  grep -Eq '^# *define OPENSSL_VERSION_PRE_RELEASE +""$' "$version_header" || return 1
  grep -Eq '^# *define OPENSSL_NO_DGRAM$' "$config_header" || return 1
  "$WASIXCC_DIR/bin/wasixnm" --defined-only --print-file-name \
    "$install_dir/lib/libcrypto.a" 2>/dev/null |
    grep -E 'libcrypto-lib-threads_pthread[.]o: .* T CRYPTO_THREAD_lock_new$' \
      >/dev/null
}

if openssl_ready; then
  echo "OpenSSL $version WASIX libraries are already installed"
  exit 0
fi

archive="$install_dir/openssl-$version.tar.gz"
source_dir="$install_dir/source"
build_dir="$install_dir/build"
url="https://github.com/openssl/openssl/releases/download/openssl-$version/openssl-$version.tar.gz"

mkdir -p "$install_dir"
sc_download "$url" "$archive" "$sha256"
if [[ ! -e "$source_dir" ]]; then
  mkdir -p "$source_dir"
  tar -xzf "$archive" -C "$source_dir" --strip-components=1
elif [[ ! -f "$source_dir/Configure" ]]; then
  sc_fail "unexpected OpenSSL source directory: $source_dir"
  exit 1
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
      --prefix="$install_dir" \
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
openssl_ready || { sc_fail "OpenSSL verification failed after installation"; exit 1; }
