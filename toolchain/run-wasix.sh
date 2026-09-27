#!/usr/bin/env bash
set -euo pipefail

# run-wasix.sh [--variant NAME] module.wasm [arguments...]: run a guest module
# under a Wasmer CLI built from source (make wasmer-<variant>), with this
# checkout visible to it at its own path, the current directory as the
# guest's, and networking on.

SC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# A service linked under work/services resolves into the Nix store. Mount the
# selected output over its link path for the guest: WASIX cannot follow a
# symlink out of its checkout volume to reach sibling modules and data files.
module_path="$(realpath -- "$module")"
store_volumes=()
if [[ "$module_path" == /nix/store/*/* ]]; then
  store_entry="${module_path#/nix/store/}"
  store_entry="${store_entry%%/*}"
  store_root="/nix/store/$store_entry"
  module_dir="$(dirname -- "$module")"
  [[ "$module_dir" == /* ]] || module_dir="$PWD/$module_dir"
  store_volumes=(--volume "$store_root:$module_dir")
fi

# An explicit --variant wins; otherwise the CLI sc_init exports for the
# service being smoke-tested; otherwise stock.
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
  "${store_volumes[@]}" \
  --cwd "$(pwd)" \
  --net \
  "$module" -- "$@"
