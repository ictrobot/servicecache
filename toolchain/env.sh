#!/usr/bin/env bash

SC_ENV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${WASIXCC_VERSION:-}" || -z "${WASIX_SYSROOT_TAG:-}" ||
      -z "${WASIX_LLVM_TAG:-}" || -z "${BINARYEN_TAG:-}" ||
      -z "${WASMER_VERSION:-}" ]]; then
  source "$SC_ENV_ROOT/toolchain/versions.sh"
fi

: "${SERVICECACHE_TOOLCHAIN_DIR:=$SC_ENV_ROOT/work/toolchains}"

WASIXCC_DIR="$SERVICECACHE_TOOLCHAIN_DIR/wasixcc/$WASIXCC_VERSION"
WASIXCC_SYSROOT_PREFIX="$SERVICECACHE_TOOLCHAIN_DIR/sysroots/$WASIX_SYSROOT_TAG"
WASIXCC_LLVM_LOCATION="$SERVICECACHE_TOOLCHAIN_DIR/llvm/$WASIX_LLVM_TAG"
WASIXCC_BINARYEN_LOCATION="$SERVICECACHE_TOOLCHAIN_DIR/binaryen/$BINARYEN_TAG"

# Wasmer CLIs are built from source per variant (see wasmer/README) and
# belong to this checkout rather than the shared toolchain directory.
WASMER_DIR="$SC_ENV_ROOT/work/wasmer/stock"

export SERVICECACHE_TOOLCHAIN_DIR
export WASIXCC_DIR WASIXCC_SYSROOT_PREFIX WASIXCC_LLVM_LOCATION
export WASIXCC_BINARYEN_LOCATION WASMER_DIR
export PATH="$WASIXCC_DIR/bin:$WASIXCC_LLVM_LOCATION/bin:$WASIXCC_BINARYEN_LOCATION/bin:$WASMER_DIR/bin:$PATH"

unset SC_ENV_ROOT
