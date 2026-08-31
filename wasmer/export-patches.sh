#!/usr/bin/env bash
set -euo pipefail

# wasmer/export-patches.sh [checkout]: regenerate every patch set from the
# stacked branches of a Wasmer dev checkout (default: work/wasmer-dev). Each
# set is one contiguous branch range; a set's branch contains the branches
# below it, so rebasing the stack keeps the layering coherent. Each file
# keeps its Subject and body and then the diff, like the service series: no
# mail headers, no diffstat, no signature.

root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/toolchain/versions.sh"

checkout="${1:-$root/work/wasmer-dev}"

# range-start range-end set-directory, innermost first.
SETS=(
  "v$WASMER_VERSION fixes wasmer/fixes/patches"
  "fixes servicecache wasmer/servicecache/patches"
)

for entry in "${SETS[@]}"; do
  read -r from to set_dir <<< "$entry"
  patch_dir="$root/$set_dir"
  rm -f "$patch_dir"/*.patch
  git -C "$checkout" format-patch --keep-subject --no-signature --quiet \
    -o "$patch_dir" "$from..$to"
  for patch in "$patch_dir"/*.patch; do
    sed -i \
      -e '1,/^Subject:/{/^Subject:/!d}' \
      -e '/^---$/,/^diff --git/{/^diff --git/!d}' \
      -e '0,/^diff --git/s//\n&/' \
      "$patch"
  done
  (cd "$patch_dir" && ls -- *.patch) > "$patch_dir/series"
done
