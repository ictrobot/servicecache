#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../toolchain/lib.sh"
sc_init postgresql "${1:?usage: ${BASH_SOURCE[0]} version}"

POSTGRESQL_OPENSSL_DIR="$(sc_lib_dir openssl "$OPENSSL_VERSION")"
export POSTGRESQL_OPENSSL_DIR

"$SC_SERVICE_DIR/libs/openssl/build.sh" "$OPENSSL_VERSION"
