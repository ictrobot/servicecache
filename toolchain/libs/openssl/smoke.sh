#!/usr/bin/env bash
set -euo pipefail

# OpenSSL's own bignum, Diffie-Hellman, DSA, RSA and elliptic-curve tests,
# compiled against the WASIX build of OpenSSL and run under Wasmer.
#
#   toolchain/libs/openssl/smoke.sh [version]
#
# tests that version, or every version a service names in its version.env,
# building it first when needed. The build has 64-bit bignum words multiplied
# through OpenSSL's 128-bit product, and OpenSSL's 64-bit P-256
# implementation (see wasix.conf), all on a 32-bit target, so these tests
# check its arithmetic. The library is configured without tests, so they are
# compiled here from its source tree with the library's own flags.

lib_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SC_ROOT="$(cd "$lib_dir/../../.." && pwd)"
source "$SC_ROOT/toolchain/lib.sh"
source "$SC_ROOT/toolchain/versions.sh"
source "$SC_ROOT/toolchain/env.sh"

# Tests run without arguments.
plain_tests=(
  bntest exptest bn_internal_test
  dhtest dsatest
  rsa_test rsa_mp_test rsa_sp800_56b_test
  ectest ec_internal_test ecdsatest
)
# bntest runs again with each of these, and evp_test with each of these.
bn_data_dir=test/recipes/10-test_bn_data
bn_data_files=(bnexp.txt bnmod.txt bnmul.txt bnshift.txt bnsum.txt bngcd.txt)
evp_data_dir=test/recipes/30-test_evp_data
evp_data_files=(evppkey_ecc.txt evppkey_ecdh.txt evppkey_ecdsa.txt evppkey_rsa.txt evppkey_rsa_common.txt)
evp_config=test/default.cnf
# Directories of the source tree the tests include from; the internal tests
# reach into crypto/.
include_dirs=(. include apps/include crypto/bn crypto/ec crypto/rsa)
# The sources of OpenSSL's test harness library, as patterns expanded inside
# the source tree.
testutil_sources=('test/testutil/*.c' apps/lib/opt.c)

test_dir=""
trap '[[ -z "$test_dir" ]] || rm -rf -- "$test_dir"' EXIT

run_tests() {
  local version="$1"
  "$lib_dir/build.sh" "$version"

  local install_dir source_dir build_dir libcrypto
  install_dir="$(sc_lib_dir openssl "$version")"
  source_dir="$install_dir/source"
  build_dir="$install_dir/build"
  libcrypto="$install_dir/lib/libcrypto.a"
  local cc="$WASIXCC_DIR/bin/wasixcc"

  mkdir -p "$SC_ROOT/work"
  test_dir="$(mktemp -d "$SC_ROOT/work/openssl-smoke.XXXXXX")"

  # The flags the library was built with, as OpenSSL's Configure recorded
  # them, and the include directories.
  local cflags dir
  read -r -a cflags < <(perl -I"$build_dir" -Mconfigdata -e 'print "@{$config{CFLAGS}}\n"')
  cflags+=(-I"$build_dir/include")
  for dir in "${include_dirs[@]}"; do
    cflags+=(-I"$source_dir/$dir")
  done

  echo "compiling OpenSSL $version test utilities"
  local pattern source object objects=()
  for pattern in "${testutil_sources[@]}"; do
    for source in "$source_dir"/$pattern; do
      object="$test_dir/$(basename "$source" .c).o"
      "$cc" "${cflags[@]}" -c "$source" -o "$object"
      objects+=("$object")
    done
  done
  "$WASIXCC_DIR/bin/wasixar" rcs "$test_dir/libtestutil.a" "${objects[@]}"

  local name
  for name in "${plain_tests[@]}" evp_test; do
    echo "compiling $name"
    "$cc" "${cflags[@]}" "$source_dir/test/$name.c" "$test_dir/libtestutil.a" "$libcrypto" \
      -o "$test_dir/$name.wasm"
  done

  # A build without the 128-bit multiply still passes every test, only
  # slower: check that the bignum code uses it, and that the 64-bit P-256
  # implementation is in the library. The counts read all their input:
  # grep -q would stop early and fail the pipeline.
  local count
  count="$("$WASIXCC_BINARYEN_LOCATION/bin/wasm-dis" "$test_dir/bntest.wasm" |
    grep -c 'i64\.mul_wide_u' || true)"
  if [[ "$count" -eq 0 ]]; then
    echo "OpenSSL's bignum code does not use the 128-bit multiply: was it configured with the wasix-wasm32 target?" >&2
    return 1
  fi
  count="$("$WASIXCC_DIR/bin/wasixnm" --defined-only "$libcrypto" 2>/dev/null |
    grep -c ' T EC_GFp_nistp256_method$' || true)"
  if [[ "$count" -eq 0 ]]; then
    echo "OpenSSL was built without its 64-bit NIST-curve implementations" >&2
    return 1
  fi

  local failed=0
  run() {
    local label="$1"
    shift
    if (cd "$test_dir" && "$SC_ROOT/toolchain/run-wasix.sh" "$@") >"$test_dir/output" 2>&1; then
      echo "ok: $label"
    else
      echo "FAILED: $label" >&2
      tail -40 "$test_dir/output" >&2
      failed=1
    fi
  }
  local data
  for name in "${plain_tests[@]}"; do
    run "$name" "$test_dir/$name.wasm"
  done
  for data in "${bn_data_files[@]}"; do
    run "bntest $data" "$test_dir/bntest.wasm" "$source_dir/$bn_data_dir/$data"
  done
  for data in "${evp_data_files[@]}"; do
    run "evp_test $data" "$test_dir/evp_test.wasm" -config "$source_dir/$evp_config" \
      "$source_dir/$evp_data_dir/$data"
  done

  rm -rf -- "$test_dir"
  test_dir=""
  return "$failed"
}

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [version]" >&2
  exit 2
fi
if [[ $# -eq 1 ]]; then
  versions=("$1")
else
  mapfile -t versions < <(sed -n 's/^OPENSSL_VERSION=//p' "$SC_ROOT"/services/*/versions/*/version.env | sort -u)
  if [[ ${#versions[@]} -eq 0 ]]; then
    echo "no service names an OpenSSL version" >&2
    exit 1
  fi
fi

for version in "${versions[@]}"; do
  run_tests "$version"
done
