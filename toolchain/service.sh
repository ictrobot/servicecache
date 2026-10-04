#!/usr/bin/env bash
# service.sh [--ccache] service version [service version]...: build through
# Nix and link each selected output in work/services. One Nix evaluation
# builds every version given. --ccache selects the package's ccache variant.
# Both link at the same path; smoke, run and lifecycle link the default build
# again unless they are given --ccache too.
set -euo pipefail

SC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SC_ROOT/toolchain/lib.sh"
build=build
attribute=""
prefix=""
if [[ "${1:-}" == --ccache ]]; then
  build=build-ccache
  attribute=.ccache
  prefix=ccache-
  shift
fi
[[ $# -ge 2 && $(($# % 2)) -eq 0 ]] || {
  sc_fail "usage: $0 [--ccache] service version [service version]..."
  exit 2
}
services=()
versions=()
installables=()
while [[ $# -gt 0 ]]; do
  service="$1"
  version="$2"
  shift 2
  [[ "$service" =~ ^[a-z0-9][a-z0-9-]*$ && "$version" =~ ^[0-9][a-zA-Z0-9.-]*$ ]] || {
    sc_fail "invalid service or version: $service $version"
    exit 2
  }
  [[ -f "$SC_ROOT/services/$service/versions/$version/version.nix" ]] || {
    sc_fail "unknown service version: $service $version"
    exit 2
  }
  destination="$SC_ROOT/work/services/$service-$version"
  [[ -L "$destination" || ! -e "$destination" ]] || {
    sc_fail "$destination is not a link; remove it with './x services --clean $service@$version'"
    exit 1
  }
  services+=("$service")
  versions+=("$version")
  installables+=(".#$service-${version//./_}$attribute")
done

mkdir -p "$SC_ROOT/work/services"
output="$("$SC_ROOT/toolchain/nix.sh" "$build" "${installables[@]}")"
mapfile -t built <<< "$output"
[[ ${#built[@]} -eq ${#installables[@]} ]] || {
  sc_fail "the build printed ${#built[@]} paths for ${#installables[@]} service versions"
  exit 1
}
# nix build prints the outputs in the order of its installables; the check on
# each output's name keeps a link from pointing at another version's build.
for index in "${!installables[@]}"; do
  service="${services[$index]}"
  version="${versions[$index]}"
  path="${built[$index]}"
  destination="$SC_ROOT/work/services/$service-$version"
  name="${path##*/}"
  [[ -d "$path" && "${name#*-}" == "$prefix$service-$version" ]] || {
    sc_fail "the build of $service-$version printed ${path:-nothing}"
    exit 1
  }
  # Building the store path evaluates nothing; --out-link registers the link
  # as a garbage collector root.
  "$SC_ROOT/toolchain/nix.sh" build "$path" --out-link "$destination" > /dev/null
  echo "${destination#"$SC_ROOT/"}: linked to $path"
done
