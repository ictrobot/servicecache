#!/usr/bin/env bash
set -euo pipefail

# Prepare the servicecache checkout used by host Cargo ([patch.crates-io] in
# Cargo.toml). Other Wasmer variants build and test in Nix.

root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/toolchain/lib.sh"
source "$root/wasmer/lib.sh"

[[ $# -eq 0 ]] || { echo "usage: $0" >&2; exit 2; }
sc_wasmer_load_variant servicecache

: "${SC_SOURCE_URL:=https://github.com/wasmerio/wasmer.git}"
sc_checkout "$SC_SOURCE_URL" "v$WASMER_VERSION" "$WASMER_VARIANT_TREE"
sets=()
for set in $WASMER_PATCH_SETS; do
  sets+=("$root/$set")
done
sc_reset_if_stale "$WASMER_VARIANT_TREE" "${sets[@]}"
for set in "${sets[@]}"; do
  sc_apply_series "$set" "$WASMER_VARIANT_TREE"
done
