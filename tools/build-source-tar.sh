#!/usr/bin/env bash
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

name="$service-$version"
source_tar=$(cd "$root" && toolchain/nix.sh build ".#${service}-${version//./_}.source")
mkdir -p "$root/work"
scratch=$(mktemp -d "$root/work/source-tar-build.XXXXXXXX")
cleanup() {
  find "$scratch" -type d -exec chmod u+w {} +
  rm -rf -- "$scratch"
}
trap cleanup EXIT

mkdir "$scratch/source"
tar --zstd -xf "$source_tar" -C "$scratch/source"
(cd "$scratch" && "$scratch/source/build.sh")

destination="$root/work/services-from-source-tar/$name"
mkdir -p "$(dirname "$destination")"
if [[ -e "$destination" || -L "$destination" ]]; then
  find "$destination" -type d -exec chmod u+w {} +
  rm -rf -- "$destination"
fi
cp -a -- "$scratch/result" "$destination"
printf '%s\n' "$destination"
