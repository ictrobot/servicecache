#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../../toolchain/lib.sh"
sc_init valkey "${1:?usage: $0 version}"
sc_clone_tag "$VALKEY_TAG" "$SC_SRC"
sc_apply_series "$SC_VERSION_DIR/patches" "$SC_SRC"
sc_apply_series "$SC_VERSION_DIR/patches/cli" "$SC_SRC"

jobs="${JOBS:-16}"
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
  echo "JOBS must be a positive integer" >&2
  exit 1
fi

wasix_cflags="--target=wasm32-wasix -matomics -mbulk-memory -mmutable-globals -pthread -mthread-model posix -ftls-model=local-exec -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -DNO_PROCESSOR_CLOCK"

make -C "$SC_SRC/src" -j"$jobs" valkey-server \
  CC="$WASIXCC_DIR/bin/wasixcc" \
  AR="$WASIXCC_DIR/bin/wasixar" \
  RANLIB="$WASIXCC_DIR/bin/wasixranlib" \
  CLANG=clang \
  MALLOC=libc \
  BUILD_TLS=no \
  BUILD_RDMA=no \
  BUILD_LUA=yes \
  USE_SYSTEMD=no \
  OPT=-O2 \
  CFLAGS="$wasix_cflags" \
  LDFLAGS=-pthread \
  FINAL_LDFLAGS="-pthread -O2" \
  FINAL_LIBS=-lm

# libvalkey is linked by valkey-cli but is not one of its Make prerequisites,
# so build it explicitly and remove the old binary to force the relink.
make -C "$SC_SRC/deps" -j"$jobs" libvalkey linenoise fpconv \
  CC="$WASIXCC_DIR/bin/wasixcc" \
  AR="$WASIXCC_DIR/bin/wasixar" \
  RANLIB="$WASIXCC_DIR/bin/wasixranlib" \
  BUILD_TLS=no \
  BUILD_RDMA=no \
  CFLAGS="$wasix_cflags" \
  LDFLAGS=-pthread

rm -f "$SC_SRC/src/valkey-cli"
make -C "$SC_SRC/src" -j"$jobs" valkey-cli \
  CC="$WASIXCC_DIR/bin/wasixcc" \
  AR="$WASIXCC_DIR/bin/wasixar" \
  RANLIB="$WASIXCC_DIR/bin/wasixranlib" \
  CLANG=clang \
  MALLOC=libc \
  BUILD_TLS=no \
  BUILD_RDMA=no \
  BUILD_LUA=yes \
  USE_SYSTEMD=no \
  OPT=-O2 \
  CFLAGS="$wasix_cflags" \
  LDFLAGS=-pthread \
  FINAL_LDFLAGS="-pthread -O2" \
  FINAL_LIBS=-lm

sc_strip "$SC_SRC/src/valkey-server" "$SC_BUILD/valkey-server.wasm"
sc_strip "$SC_SRC/src/valkey-cli" "$SC_BUILD/valkey-cli.wasm"

sc_assemble "$SC_BUILD/valkey-server.wasm" "$SC_BUILD/valkey-cli.wasm"
sc_write_build_info
