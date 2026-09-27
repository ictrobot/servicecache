#!/usr/bin/env bash
# service.sh [--ccache] service version: build through Nix and link the selected
# output in work/services. --ccache selects the package's ccache variant.
# Smoke, run and lifecycle targets select the default build again.
set -euo pipefail

SC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SC_ROOT/toolchain/lib.sh"
build=build
attribute=""
if [[ "${1:-}" == --ccache ]]; then
  build=build-ccache
  attribute=.ccache
  shift
fi
[[ $# -eq 2 ]] || { sc_fail "usage: $0 [--ccache] service version"; exit 2; }
service="$1"
version="$2"
[[ "$service" =~ ^[a-z0-9][a-z0-9-]*$ && "$version" =~ ^[0-9][a-zA-Z0-9.-]*$ ]] || {
  sc_fail "invalid service or version: $service $version"
  exit 2
}
[[ -f "$SC_ROOT/services/$service/versions/$version/version.nix" ]] || {
  sc_fail "unknown service version: $service $version"
  exit 2
}

destination="$SC_ROOT/work/services/$service-$version"
mkdir -p "$(dirname "$destination")"
[[ -L "$destination" || ! -e "$destination" ]] || {
  sc_fail "$destination is not a link; remove it with make clean-service-$service-$version"
  exit 1
}
built="$("$SC_ROOT/toolchain/nix.sh" "$build" ".#$service-${version//./_}$attribute" --out-link "$destination")"
[[ -d "$built" ]] || {
  sc_fail "the build of $service-$version printed no directory: ${built:-nothing}"
  exit 1
}
echo "${destination#"$SC_ROOT/"}: linked to $built"
