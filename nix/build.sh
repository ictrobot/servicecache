#!/usr/bin/env bash
# Build from an extracted source tar using downloaded Nixpkgs tools.
set -euo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
result_dir="$(pwd -P)/result"
if [[ -e "$result_dir" || -L "$result_dir" ]]; then
  printf 'Result path already exists: %s\n' "$result_dir" >&2
  exit 1
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/servicecache-build.XXXXXXXX")
store="$scratch/store"
cleanup() {
  find "$scratch" -type d -exec chmod u+w {} +
  rm -rf -- "$scratch"
}
trap cleanup EXIT

# Prepare downloads the Nixpkgs build tools; it does not include guest sources.
printf 'Preparing Nixpkgs tools from %s\n' "$source_dir" >&2
prepared=$(
  nix --extra-experimental-features 'nix-command flakes' build \
    --no-link --print-out-paths --print-build-logs \
    "path:$source_dir#prepare"
)
printf 'Prepared closure: %s\n' "$prepared" >&2
nixpkgs=$(readlink -f "$prepared/nixpkgs")

printf 'Creating build store at %s\n' "$store" >&2
unshare --user --map-root-user --mount --net -- \
  bash -s -- "$store" "$prepared" "$nixpkgs" "$source_dir" "$result_dir" <<'BUILD'
  set -euo pipefail

  store=$1
  prepared=$2
  nixpkgs=$3
  source_dir=$4
  result_dir=$5

  ip link set lo up
  nix_options=(
    --extra-experimental-features 'nix-command flakes'
    --option build-users-group ''
    --option require-drop-supplementary-groups false
  )

  printf 'Copying downloaded tools into the build store\n' >&2
  nix "${nix_options[@]}" copy --to "$store" --no-check-sigs "$prepared"

  printf 'Building service\n' >&2
  output=$(
    nix "${nix_options[@]}" build \
      --store "$store" --offline \
      --option substituters '' --option builders '' \
      --override-input nixpkgs "path:$nixpkgs" \
      --no-link --print-out-paths --print-build-logs \
      "path:$source_dir#default"
  )
  store_hash=$(nix "${nix_options[@]}" hash path "$store$output")
  printf 'Store path: %s\n' "$output" >&2
  printf 'Copying output to %s\n' "$result_dir" >&2
  cp -a -- "$store$output" "$result_dir"
  result_hash=$(nix "${nix_options[@]}" hash path "$result_dir")
  if [[ "$result_hash" != "$store_hash" ]]; then
    printf 'Copied output hash differs from store output: %s != %s\n' "$result_hash" "$store_hash" >&2
    exit 1
  fi
  printf 'Result: %s\nNAR hash: %s\n' "$result_dir" "$result_hash"
BUILD
