#!/usr/bin/env bash
set -euo pipefail

# The WASIX build of OpenSSL: the static libcrypto and libssl a service links
# against to speak TLS, and the headers it compiles against, as lib and
# include in SC_OUT_DIR.

source "${SC_TOOLCHAIN:?}/guest-lib.sh"
sc_library_init openssl "${1:?usage: $0 version}"

# Built inside a copy of its tree, so that the source paths the libraries
# record are files' places in OpenSSL rather than paths of this build.
build_dir="$SC_BUILD_DIR/openssl"
stage_dir="$SC_BUILD_DIR/install"
sc_copy_source "$SC_SOURCE_OPENSSL_DIR" "$build_dir"

# The wasix-wasm32 target keeps assembly enabled, so there is no no-asm here;
# see wasix.conf. no-atexit leaves libcrypto's tables to go with the process's
# memory rather than freeing each of them as the process exits. No --prefix:
# libcrypto records the directory it reads openssl.cnf from, and the default
# is the same wherever this runs, which a directory of the build is not.
(
  cd "$build_dir"
  sc_guest env \
    CC="${SC_CCACHE:+$SC_CCACHE }guest-cc" \
    CXX="${SC_CCACHE:+$SC_CCACHE }guest-c++" \
    AR=guest-ar \
    RANLIB=guest-ranlib \
    CFLAGS="-DUSE_TIMEGM -DOPENSSL_NO_SECURE_MEMORY -DOPENSSL_NO_DGRAM -DOPENSSL_THREADS -O2" \
    LDFLAGS="-Wl,--allow-undefined" \
    perl ./Configure --config="$SC_LIBRARY_DIR/wasix.conf" wasix-wasm32 \
      --libdir=lib \
      -static \
      no-shared \
      no-pic \
      no-dso \
      no-tests \
      no-apps \
      no-afalgeng \
      no-dgram \
      no-atexit \
      -DUSE_TIMEGM \
      -DOPENSSL_NO_SECURE_MEMORY \
      -DOPENSSL_NO_DGRAM \
      -DOPENSSL_THREADS
)

sc_guest make -C "$build_dir" -j"$JOBS" build_libs
sc_guest make -C "$build_dir" install_dev DESTDIR="$stage_dir"

mkdir -p "$SC_OUT_DIR/lib"
cp -a "$stage_dir/usr/local/include" "$SC_OUT_DIR/include"
cp -a "$stage_dir/usr/local/lib/libcrypto.a" "$stage_dir/usr/local/lib/libssl.a" "$SC_OUT_DIR/lib/"

# What Configure gives up quietly rather than failing on: the version, the
# options and target wasix.conf describes, and real pthread locking.
version_header="$SC_OUT_DIR/include/openssl/opensslv.h"
config_header="$SC_OUT_DIR/include/openssl/configuration.h"
IFS=. read -r version_major version_minor version_patch <<<"$SC_VERSION"
grep -Eq "^# *define OPENSSL_VERSION_MAJOR +${version_major}$" "$version_header" &&
  grep -Eq "^# *define OPENSSL_VERSION_MINOR +${version_minor}$" "$version_header" &&
  grep -Eq "^# *define OPENSSL_VERSION_PATCH +${version_patch}$" "$version_header" &&
  grep -Eq '^# *define OPENSSL_VERSION_PRE_RELEASE +""$' "$version_header" ||
  sc_fail "SC_SOURCE_OPENSSL_DIR does not hold OpenSSL $SC_VERSION"
grep -Eq '^# *define OPENSSL_NO_DGRAM$' "$config_header" &&
  grep -Eq '^# *define OPENSSL_NO_ATEXIT$' "$config_header" &&
  grep -Eq '^# *define SIXTY_FOUR_BIT$' "$config_header" &&
  ! grep -q 'OPENSSL_NO_ASM' "$config_header" &&
  ! grep -q 'OPENSSL_NO_EC_NISTP_64_GCC_128' "$config_header" ||
  sc_fail "OpenSSL was not configured as build.sh and wasix.conf ask"
guest-nm --defined-only --print-file-name "$SC_OUT_DIR/lib/libcrypto.a" 2>/dev/null |
  grep -E 'libcrypto-lib-threads_pthread[.]o: .* T CRYPTO_THREAD_lock_new$' >/dev/null ||
  sc_fail "libcrypto was built without pthread locking"
