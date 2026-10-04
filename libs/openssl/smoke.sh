#!/usr/bin/env bash
set -euo pipefail

# OpenSSL's own bignum, Diffie-Hellman, DSA, RSA and elliptic-curve tests,
# compiled against the WASIX build of OpenSSL and run under Wasmer.
#
#   libs/openssl/smoke.sh
#
# Tests the OpenSSL library the services link, as libs/openssl builds it.
# The build has 64-bit bignum words multiplied through OpenSSL's 128-bit
# product, and OpenSSL's 64-bit P-256 implementation (see wasix.conf), all on
# a 32-bit target, so these tests check its arithmetic. smoke-build.sh
# compiles them, as the flake's smoke-openssl.

SC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# bntest runs again with each of these, and evp_test with each of these.
bn_data_dir=test/recipes/10-test_bn_data
bn_data_files=(bnexp.txt bnmod.txt bnmul.txt bnshift.txt bnsum.txt bngcd.txt)
evp_data_dir=test/recipes/30-test_evp_data
evp_data_files=(evppkey_ecc.txt evppkey_ecdh.txt evppkey_ecdsa.txt evppkey_rsa.txt evppkey_rsa_common.txt)
evp_config=test/default.cnf

test_dir=""
trap '[[ -z "$test_dir" ]] || rm -rf -- "$test_dir"' EXIT

run_tests() {
  local built="$SC_ROOT/work/build/lib-smoke/openssl"
  [[ -d "$built" ]] || {
    echo "error: tests not built: $built (run './x smoke --lib openssl')" >&2
    exit 1
  }

  # The modules run from a copy under the checkout, which is what
  # run-wasix.sh lets a guest see.
  mkdir -p "$SC_ROOT/work"
  test_dir="$(mktemp -d "$SC_ROOT/work/openssl-smoke.XXXXXX")"
  cp -r "$built/." "$test_dir/"
  chmod -R u+w "$test_dir"

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
  local name data
  while IFS= read -r name; do
    run "$name" "$test_dir/$name.wasm"
  done < "$test_dir/plain-tests"
  for data in "${bn_data_files[@]}"; do
    run "bntest $data" "$test_dir/bntest.wasm" "$test_dir/$bn_data_dir/$data"
  done
  for data in "${evp_data_files[@]}"; do
    run "evp_test $data" "$test_dir/evp_test.wasm" -config "$test_dir/$evp_config" \
      "$test_dir/$evp_data_dir/$data"
  done

  rm -rf -- "$test_dir"
  test_dir=""
  return "$failed"
}

if [[ $# -ne 0 ]]; then
  echo "usage: $0" >&2
  exit 2
fi
run_tests
