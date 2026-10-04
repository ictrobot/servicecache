#!/usr/bin/env bash
set -euo pipefail

source "${SC_TOOLCHAIN:?}/guest-lib.sh"
sc_build_init nats-server "${1:?usage: $0 version}"

# go build reads the module's dependencies from vendor/ at its root, so the
# tree is copied and the vendored modules placed inside it.
tree="$SC_BUILD_DIR/nats-server"
sc_copy_source "$SC_SOURCE_NATS_SERVER_DIR" "$tree"
sc_copy_source "$SC_SOURCE_GO_MODULES_DIR" "$tree/vendor"

# The toolchain's environment selects wasip1, the wasix tag and vendor mode.
sc_go -C "$tree" build -v -o "$SC_BUILD_DIR/nats-server.wasm" .

sc_assemble "$SC_BUILD_DIR/nats-server.wasm"
