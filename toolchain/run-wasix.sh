#!/usr/bin/env bash
set -euo pipefail

SC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SC_ROOT/toolchain/versions.sh"
source "$SC_ROOT/toolchain/env.sh"

variant=stock
if [[ "${1:-}" == "--variant" ]]; then
  variant="${2:?--variant needs a name}"
  shift 2
fi

if [[ $# -lt 1 ]]; then
  echo "usage: $0 [--variant NAME] module.wasm [arguments...]" >&2
  exit 2
fi

module="$1"
shift

wasmer="$SC_ROOT/work/wasmer/$variant/bin/wasmer"
if [[ ! -x "$wasmer" ]]; then
  echo "Wasmer variant not built: run make wasmer-$variant first" >&2
  exit 1
fi

exec "$wasmer" run \
  --volume "$SC_ROOT:$SC_ROOT" \
  --cwd "$(pwd)" \
  --net \
  "$module" -- "$@"
