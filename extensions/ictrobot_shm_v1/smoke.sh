#!/usr/bin/env bash
set -euo pipefail

# Builds the ictrobot_shm_v1 demo and runs it under the extensions Wasmer
# variant, showing the guest runs standalone without the servicecache patches.
# The stock CLI must then refuse the module: a guest that imports the
# namespace fails loudly anywhere the imports are absent.

SC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SC_ROOT/toolchain/versions.sh"
source "$SC_ROOT/toolchain/env.sh"

extensions_cli="$SC_ROOT/work/wasmer/extensions/bin/wasmer"
stock_cli="$SC_ROOT/work/wasmer/stock/bin/wasmer"
for cli in "$extensions_cli" "$stock_cli"; do
  [[ -x "$cli" ]] || {
    echo "Wasmer variant not built: run make wasmer-extensions and make wasmer-stock first" >&2
    exit 1
  }
done

build_dir="$SC_ROOT/work/build/extension-smoke/ictrobot_shm_v1"
mkdir -p "$build_dir"
module="$build_dir/ictrobot-shm-demo.wasm"

"$WASIXCC_DIR/bin/wasixcc" -O2 -pthread \
  -I "$SC_ROOT/extensions/ictrobot_shm_v1" \
  "$SC_ROOT/extensions/ictrobot_shm_v1/demo.c" -o "$module"

# The demo spawns its child by name, found through PATH in the mapped dir.
output="$("$extensions_cli" run --volume "$build_dir:$build_dir" --env "PATH=$build_dir" "$module")"
expected=$'asked 21, child answered 42\nictrobot_shm_v1 demo: parent and child shared one page'
[[ "$output" == "$expected" ]] || {
  echo "unexpected demo output: $output" >&2
  exit 1
}
printf '%s\n' "$output"

if stock_output="$("$stock_cli" run --volume "$build_dir:$build_dir" --env "PATH=$build_dir" "$module" 2>&1)"; then
  echo "stock Wasmer ran a module that imports ictrobot_shm_v1" >&2
  exit 1
fi
grep -q 'ictrobot_shm_v1' <<<"$stock_output" || {
  echo "stock Wasmer failed for another reason: $stock_output" >&2
  exit 1
}
echo "stock Wasmer refuses the ictrobot_shm_v1 import, as it must"
