#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../../toolchain/lib.sh"
sc_init beanstalkd "${1:?usage: $0 version}"
sc_clone_tag "$BEANSTALKD_TAG" "$SC_SRC"
sc_apply_series "$SC_VERSION_DIR/patches" "$SC_SRC"

make -C "$SC_SRC" clean all \
  OS=linux \
  USE_SYSTEMD=no \
  CC="$WASIXCC_DIR/bin/wasixcc" \
  CFLAGS="${CFLAGS:--O2}" \
  LDFLAGS="${LDFLAGS:-}" \
  LDLIBS=""

mkdir -p "$SC_BUILD"
"$WASIXCC_BINARYEN_LOCATION/bin/wasm-opt" "$SC_SRC/beanstalkd" \
  --strip-debug \
  -o "$SC_BUILD/beanstalkd.wasm"
chmod +x "$SC_BUILD/beanstalkd.wasm"

sc_assemble beanstalkd "$SERIES" "$SC_BUILD/beanstalkd.wasm"
sc_write_build_info
