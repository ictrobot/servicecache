#!/usr/bin/env bash
# Link a Nix-built Wasmer CLI at work/wasmer/<variant> for the host smoke tests.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
variant="${1:?usage: $0 variant}"
[[ $# -eq 1 && "$variant" =~ ^[a-z][a-z0-9-]*$ && -f "$root/wasmer/$variant/patches.list" ]] || {
  echo "unknown Wasmer variant: $variant" >&2
  exit 2
}

out="$root/work/wasmer/$variant"
mkdir -p "$(dirname "$out")"
[[ -L "$out" || ! -e "$out" ]] || {
  echo "$out is not a link; remove it with make clean-wasmer-$variant" >&2
  exit 1
}
built="$("$root/toolchain/nix.sh" build ".#wasmer-$variant" --out-link "$out")"
cli="$built/bin/wasmer"
version="$(cat "$root/wasmer/version")"
[[ -x "$cli" && "$("$cli" --version)" == "wasmer $version" &&
   "$("$cli" --version --verbose | grep '^runtimes:')" == "runtimes: Cranelift" ]] || {
  echo "Wasmer $variant did not build as the Cranelift-only $version CLI" >&2
  exit 1
}
echo "${out#"$root/"}: linked to $built"
