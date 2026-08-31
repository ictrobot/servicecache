#!/usr/bin/env bash
set -euo pipefail

# wasmer/build.sh <variant>: build the variant's Wasmer CLI from source and
# install it at work/wasmer/<variant>/bin/wasmer. Only bin/wasmer is used,
# and the upstream release binary needs a newer libstdc++ than some
# distributions carry, so every variant is built from the pinned tag with
# the Cranelift backend and the artifact features used here. Wasmer's
# BUSL-1.1 Singlepass and LLVM backends are not built. The install is
# stamped with the variant's patch-set hash, so a changed series
# rebuilds it.

root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/toolchain/lib.sh"
source "$root/toolchain/versions.sh"
source "$root/wasmer/lib.sh"

sc_wasmer_load_variant "${1:?usage: $0 variant}"

out="$root/work/wasmer/$WASMER_VARIANT"
build_dir="$root/work/build/wasmer/$WASMER_VARIANT"
hash="$(sc_wasmer_sets_hash)"

if [[ -x "$out/bin/wasmer" &&
      "$("$out/bin/wasmer" --version 2>&1)" == "wasmer $WASMER_VERSION" &&
      -f "$out/sets-hash" && "$(cat "$out/sets-hash")" == "$hash" ]]; then
  echo "Wasmer $WASMER_VERSION ($WASMER_VARIANT) is already built"
  exit 0
fi

command -v cargo >/dev/null 2>&1 || {
  echo "required host command not found: cargo" >&2
  exit 1
}

echo "building the Wasmer $WASMER_VERSION CLI from source ($WASMER_VARIANT)"
"$root/wasmer/setup.sh" "$WASMER_VARIANT"
sc_wasmer_napi_submodule "$WASMER_VARIANT_TREE"

CARGO_TARGET_DIR="$build_dir" cargo build --release --locked \
  --manifest-path "$WASMER_VARIANT_TREE/lib/cli/Cargo.toml" --bin wasmer \
  --features cranelift,wasmer-artifact-create,static-artifact-create,wasmer-artifact-load,static-artifact-load

install -D -m 755 "$build_dir/release/wasmer" "$out/bin/wasmer"
echo "$hash" > "$out/sets-hash"
[[ "$("$out/bin/wasmer" --version 2>&1)" == "wasmer $WASMER_VERSION" ]] || {
  echo "Wasmer verification failed after building the CLI ($WASMER_VARIANT)" >&2
  exit 1
}
