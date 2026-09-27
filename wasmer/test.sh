#!/usr/bin/env bash
# Run the unit tests of a patched Wasmer variant through Nix.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
variant="${1:?usage: $0 variant}"
[[ $# -eq 1 && "$variant" =~ ^[a-z][a-z0-9-]*$ && -f "$root/wasmer/$variant/patches.list" ]] || {
  echo "unknown Wasmer variant: $variant" >&2
  exit 2
}
"$root/toolchain/nix.sh" build ".#wasmer-$variant-tests" >/dev/null
