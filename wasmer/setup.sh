#!/usr/bin/env bash
set -euo pipefail

# wasmer/setup.sh <variant>: check the pinned Wasmer tag out into
# work/src/wasmer/<variant> and apply the variant's patch sets, in order,
# idempotently. The servicecache variant's checkout is what the workspace
# builds the host against ([patch.crates-io] in Cargo.toml).

root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/toolchain/lib.sh"
source "$root/toolchain/versions.sh"
source "$root/wasmer/lib.sh"

sc_wasmer_load_variant "${1:?usage: $0 variant}"

: "${SC_SOURCE_URL:=https://github.com/wasmerio/wasmer.git}"
sc_checkout "$SC_SOURCE_URL" "v$WASMER_VERSION" "$WASMER_VARIANT_TREE"
for set in $WASMER_PATCH_SETS; do
  sc_apply_series "$root/$set" "$WASMER_VARIANT_TREE"
done
