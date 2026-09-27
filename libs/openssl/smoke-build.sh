#!/usr/bin/env bash
set -euo pipefail

# Compile what smoke.sh runs: OpenSSL's own bignum, Diffie-Hellman, DSA, RSA
# and elliptic-curve tests, linked against the library services are handed.
#
#   SC_LIBRARY_OPENSSL_DIR     the library, as build.sh assembled it
#   SC_LIBRARY_DIR             the build recipe and its wasix.conf
#   SC_OPENSSL_SMOKE_SOURCE_DIR  the full release; the reduced source
#                                omits the tests
#   SC_BUILD_DIR, SC_OUT_DIR   where to build, and where the tests and the
#                              data they read go
#
# and the guest toolchain on PATH, as in any guest build. The library
# is configured without tests, so they are compiled here with the flags
# Configure recorded, against the internal headers of a build tree. That tree
# is build.sh's own, run on the whole release, and the libraries it makes must
# be the ones handed in: a patched source tree that lacked something the build
# reads would show here.

version="${1:?usage: $0 version}"
: "${SC_LIBRARY_DIR:?} ${SC_LIBRARY_OPENSSL_DIR:?} ${SC_OPENSSL_SMOKE_SOURCE_DIR:?} ${SC_BUILD_DIR:?} ${SC_OUT_DIR:?}"
source "${SC_TOOLCHAIN:?}/guest-lib.sh"
mkdir -p "$SC_BUILD_DIR" "$SC_OUT_DIR"

# Tests run without arguments.
plain_tests=(
  bntest exptest bn_internal_test
  dhtest dsatest
  rsa_test rsa_mp_test rsa_sp800_56b_test
  ectest ec_internal_test ecdsatest
)
# What smoke.sh runs bntest and evp_test again with.
data_files=(
  test/recipes/10-test_bn_data
  test/recipes/30-test_evp_data
  test/default.cnf
)
# Directories of the source tree the tests include from; the internal tests
# reach into crypto/.
include_dirs=(. include apps/include crypto/bn crypto/ec crypto/rsa)
# The sources of OpenSSL's test harness library, as patterns expanded inside
# the source tree.
testutil_sources=('test/testutil/*.c' apps/lib/opt.c)

release="$SC_BUILD_DIR/release"
mkdir -p "$release"
cp -r "$SC_OPENSSL_SMOKE_SOURCE_DIR"/. "$release"/
chmod -R u+w "$release"
rebuilt="$SC_BUILD_DIR/rebuilt"
tree="$SC_BUILD_DIR/library/openssl"
SC_SOURCE_OPENSSL_DIR="$release" SC_BUILD_DIR="$SC_BUILD_DIR/library" \
  SC_OUT_DIR="$rebuilt" \
  bash "$SC_LIBRARY_DIR/build.sh" "$version" > "$SC_BUILD_DIR/library.log" 2>&1 ||
  { tail -n 40 "$SC_BUILD_DIR/library.log" >&2; exit 1; }
for archive in libcrypto.a libssl.a; do
  cmp "$rebuilt/lib/$archive" "$SC_LIBRARY_OPENSSL_DIR/lib/$archive" || {
    echo "error: $archive built from the whole release is not the $archive handed in" >&2
    exit 1
  }
done
libcrypto="$SC_LIBRARY_OPENSSL_DIR/lib/libcrypto.a"

read -r -a cflags < <(perl -I"$tree" -Mconfigdata -e 'print "@{$config{CFLAGS}}\n"')
for dir in "${include_dirs[@]}"; do
  cflags+=(-I"$tree/$dir")
done

objects_dir="$SC_BUILD_DIR/tests"
mkdir -p "$objects_dir" "$SC_OUT_DIR"
echo "compiling OpenSSL $version test utilities"
objects=()
for pattern in "${testutil_sources[@]}"; do
  for source in "$tree"/$pattern; do
    object="$objects_dir/$(basename "$source" .c).o"
    guest-cc "${cflags[@]}" -c "$source" -o "$object"
    objects+=("$object")
  done
done
guest-ar rcs "$objects_dir/libtestutil.a" "${objects[@]}"

for name in "${plain_tests[@]}" evp_test; do
  echo "compiling $name"
  guest-cc "${cflags[@]}" "$tree/test/$name.c" "$objects_dir/libtestutil.a" "$libcrypto" \
    -o "$SC_OUT_DIR/$name.wasm"
done
printf '%s\n' "${plain_tests[@]}" > "$SC_OUT_DIR/plain-tests"
(cd "$tree" && cp -r --parents "${data_files[@]}" "$SC_OUT_DIR/")

# A build without the 128-bit multiply still passes every test, only slower:
# check that the bignum code uses it, and that the 64-bit P-256 implementation
# is in the library. The counts read all their input: grep -q would stop early
# and fail the pipeline.
count="$(wasm-dis "$SC_OUT_DIR/bntest.wasm" |
  grep -c 'i64\.mul_wide_u' || true)"
if [[ "$count" -eq 0 ]]; then
  echo "OpenSSL's bignum code does not use the 128-bit multiply: was it configured with the wasix-wasm32 target?" >&2
  exit 1
fi
count="$(guest-nm --defined-only "$libcrypto" 2>/dev/null |
  grep -c ' T EC_GFp_nistp256_method$' || true)"
if [[ "$count" -eq 0 ]]; then
  echo "OpenSSL was built without its 64-bit NIST-curve implementations" >&2
  exit 1
fi
