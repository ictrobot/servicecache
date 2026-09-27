#!/usr/bin/env bash
set -euo pipefail

source "${SC_TOOLCHAIN:?}/guest-lib.sh"
sc_build_init beanstalkd "${1:?usage: $0 version}"

# The makefile compiles beside its sources, so the build has a copy of them.
tree="$SC_BUILD_DIR/beanstalkd"
sc_copy_source "$SC_SOURCE_BEANSTALKD_DIR" "$tree"

sc_guest make -C "$tree" -j"$JOBS" all \
  OS=linux \
  USE_SYSTEMD=no \
  CC="${SC_CCACHE:+$SC_CCACHE }guest-cc" \
  CFLAGS=-O2 \
  LDLIBS=""

# The makefile links without CFLAGS, so with no optimisation level.
sc_strip 0 "$tree/beanstalkd" "$SC_BUILD_DIR/beanstalkd.wasm"

sc_assemble "$SC_BUILD_DIR/beanstalkd.wasm"
