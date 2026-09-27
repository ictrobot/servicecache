#!/usr/bin/env bash
# Check the service source tar's build and regenerate it from the ServiceCache source inside it.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  printf 'Usage: %s SERVICE VERSION\n' "$0" >&2
  exit 2
fi

service=$1
version=$2
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
if [[ ! "$service" =~ ^[a-z0-9][a-z0-9-]*$ || ! "$version" =~ ^[0-9][a-zA-Z0-9.-]*$ ||
      ! -f "$root/services/$service/versions/$version/version.nix" ]]; then
  printf 'Unknown service version: %s-%s\n' "$service" "$version" >&2
  exit 2
fi
attribute="$service-${version//./_}"
scratch=$(mktemp -d "$root/work/source-tar.XXXXXXXX")
cleanup() {
  find "$scratch" -type d -exec chmod u+w {} +
  rm -rf -- "$scratch"
}
trap cleanup EXIT
mkdir "$scratch/service-source"
nix=(nix --extra-experimental-features 'nix-command flakes')

printf 'Building service source tar for %s-%s\n' "$service" "$version" >&2
service_source_tar=$("${nix[@]}" build --no-link --print-out-paths "$root#$attribute.source")
service_source_hash=$(sha256sum "$service_source_tar")
service_source_hash=${service_source_hash%% *}
printf 'Service source tar: %s\nSHA-256: %s\n' "$service_source_tar" "$service_source_hash" >&2
system=$("${nix[@]}" config show system)
expected_drv=$("${nix[@]}" eval --raw "$root#legacyPackages.$system.$attribute.drvPath")
printf 'Service derivation: %s\n' "$expected_drv" >&2

# Compare drvPaths: the extracted flake must resolve its own source files
# and verified embedded tars to the same service build.
tar --zstd -xf "$service_source_tar" -C "$scratch/service-source"
printf 'Checking the extracted service source tar and its embedded source tars\n' >&2
extracted_drv=$("${nix[@]}" eval --offline --option substituters '' --raw \
  "path:$scratch/service-source#packages.$system.$attribute.drvPath")
if [[ "$extracted_drv" != "$expected_drv" ]]; then
  printf 'Service source tar derivation differs: expected %s, got %s\n' \
    "$expected_drv" "$extracted_drv" >&2
  exit 1
fi
printf 'Service source tar evaluates to the same service derivation\n' >&2

printf 'Building the service source tar from its ServiceCache source in a fresh store\n' >&2
rebuilt_service_source_tar=$(
  unshare --user --map-root-user --mount -- \
    bash -s -- "$scratch/fresh-store" "$scratch/service-source/servicecache" "$attribute" <<'BUILD'
  set -euo pipefail
  store=$1
  servicecache_source_dir=$2
  attribute=$3
  nix_options=(
    --extra-experimental-features 'nix-command flakes'
    --option build-users-group ''
    --option require-drop-supplementary-groups false
    --option substituters https://cache.nixos.org/
    --option builders ''
  )

  nix "${nix_options[@]}" build --store "$store" --no-link \
    --print-out-paths "path:$servicecache_source_dir#$attribute.source"
BUILD
)
# Compare hashes: the fresh-store build follows recipes in the ServiceCache
# source to recreate upstream source tars and assemble the same bytes.
rebuilt_hash=$(sha256sum "$scratch/fresh-store$rebuilt_service_source_tar")
rebuilt_hash=${rebuilt_hash%% *}
if [[ "$rebuilt_hash" != "$service_source_hash" ]]; then
  printf 'Rebuilt service source tar hash differs: expected %s, got %s\n' \
    "$service_source_hash" "$rebuilt_hash" >&2
  exit 1
fi
printf 'Rebuilt service source tar matches SHA-256 %s\n' "$service_source_hash" >&2
