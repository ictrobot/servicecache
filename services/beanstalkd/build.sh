#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../../toolchain/lib.sh"
sc_init beanstalkd "${1:?usage: $0 version}"
sc_clean_if_toolchain_changed
: "${SC_SOURCE_URL:=https://github.com/beanstalkd/beanstalkd.git}"
: "${BEANSTALKD_TAG:=v$SC_VERSION}"
sc_checkout "$SC_SOURCE_URL" "$BEANSTALKD_TAG" "$SC_SRC"
sc_apply_series "$SC_VERSION_DIR/patches" "$SC_SRC"

make -C "$SC_SRC" all \
  OS=linux \
  USE_SYSTEMD=no \
  CC="$WASIXCC_DIR/bin/wasixcc" \
  CFLAGS="${CFLAGS:--O2}" \
  LDFLAGS="${LDFLAGS:-}" \
  LDLIBS=""

sc_strip "$SC_SRC/beanstalkd" "$SC_BUILD/beanstalkd.wasm"

sc_assemble "$SC_BUILD/beanstalkd.wasm"
sc_write_build_info
