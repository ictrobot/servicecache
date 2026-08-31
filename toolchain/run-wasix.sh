#!/usr/bin/env bash
set -euo pipefail

SC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SC_ROOT/toolchain/versions.sh"
source "$SC_ROOT/toolchain/env.sh"

variant=""
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

# An explicit --variant wins; otherwise the CLI sc_init exports for the
# package being built or smoke-tested; otherwise stock.
if [[ -n "$variant" ]]; then
  wasmer="$SC_ROOT/work/wasmer/$variant/bin/wasmer"
else
  wasmer="${SC_WASMER:-$SC_ROOT/work/wasmer/stock/bin/wasmer}"
fi
if [[ ! -x "$wasmer" ]]; then
  variant="$(basename "$(dirname "$(dirname "$wasmer")")")"
  echo "Wasmer CLI not built: $wasmer (run make wasmer-$variant first)" >&2
  exit 1
fi

exec "$wasmer" run \
  --volume "$SC_ROOT:$SC_ROOT" \
  --cwd "$(pwd)" \
  --net \
  "$module" -- "$@"
