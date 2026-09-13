#!/usr/bin/env bash
set -euo pipefail

# wasmer/export-patches.sh [checkout]: regenerate every patch set from the
# stacked branches of a Wasmer dev checkout (default: work/wasmer-dev). Each
# set is one contiguous branch range, as sc_wasmer_dev_sets lists them.

root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/toolchain/versions.sh"
source "$root/wasmer/lib.sh"

checkout="${1:-$root/work/wasmer-dev}"

while read -r from to set_dir; do
  sc_wasmer_export_range "$checkout" "$from" "$to" "$root/$set_dir"
done < <(sc_wasmer_dev_sets)
