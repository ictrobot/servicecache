#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../../toolchain/lib.sh"
sc_init valkey "${1:?usage: $0 version}"
sc_clean_if_toolchain_changed
: "${SC_SOURCE_URL:=https://github.com/valkey-io/valkey.git}"
: "${VALKEY_TAG:=$SC_VERSION}"
sc_checkout "$SC_SOURCE_URL" "$VALKEY_TAG" "$SC_SRC"
sc_apply_series "$SC_VERSION_DIR/patches" "$SC_SRC"

jobs="${JOBS:-16}"
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
  echo "JOBS must be a positive integer" >&2
  exit 1
fi

# Bundled libraries that differ between Valkey release series: 9.x replaced
# hiredis with libvalkey and moved the Lua engine into a module, which is
# linked statically here.
case "$SC_VERSION" in
  7.2.*|8.1.*)
    client_lib=hiredis
    series_options=()
    ;;
  9.*)
    client_lib=libvalkey
    series_options=(BUILD_LUA=yes)
    ;;
  *)
    sc_fail "no build options defined for Valkey $SC_VERSION"
    ;;
esac

wasix_cflags="--target=wasm32-wasix -matomics -mbulk-memory -mmutable-globals -pthread -mthread-model posix -ftls-model=local-exec -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -DNO_PROCESSOR_CLOCK"

make -C "$SC_SRC/src" -j"$jobs" valkey-server \
  CC="$WASIXCC_DIR/bin/wasixcc" \
  AR="$WASIXCC_DIR/bin/wasixar" \
  RANLIB="$WASIXCC_DIR/bin/wasixranlib" \
  CLANG=clang \
  MALLOC=libc \
  BUILD_TLS=no \
  BUILD_RDMA=no \
  "${series_options[@]}" \
  USE_SYSTEMD=no \
  OPT=-O2 \
  CFLAGS="$wasix_cflags" \
  LDFLAGS=-pthread \
  FINAL_LDFLAGS="-pthread -O2" \
  FINAL_LIBS=-lm

# The client library is linked by valkey-cli but is not one of its Make
# prerequisites, so build it explicitly and remove the old binary to force
# the relink.
make -C "$SC_SRC/deps" -j"$jobs" "$client_lib" linenoise fpconv \
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
  "${series_options[@]}" \
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
