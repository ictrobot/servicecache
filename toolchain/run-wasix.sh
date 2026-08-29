#!/usr/bin/env bash
set -euo pipefail

SC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SC_ROOT/toolchain/versions.sh"
source "$SC_ROOT/toolchain/env.sh"

if [[ $# -lt 1 ]]; then
  echo "usage: $0 module.wasm [arguments...]" >&2
  exit 2
fi

module="$1"
shift

if [[ ! -x "$WASMER_DIR/bin/wasmer" ]]; then
  echo "Wasmer not found; run toolchain/bootstrap.sh first" >&2
  exit 1
fi

exec "$WASMER_DIR/bin/wasmer" run \
  --volume "$SC_ROOT:$SC_ROOT" \
  --cwd "$(pwd)" \
  --net \
  "$module" -- "$@"
