#!/usr/bin/env bash
set -euo pipefail

# wasmer/test.sh <variant> [cargo test arguments...]: run the unit tests of
# the workspace crates that go into the CLIs we build — a superset of every
# crate the patch sets modify — inside the variant's checkout, so that
# patches carry their tests and the tests actually run, and stock is the
# unpatched baseline. Unit tests only (--lib): upstream's integration
# targets range from fixture runners to a rig that compiles guest programs
# with tooling this repo does not install, and the codegen backends we do
# not build (LLVM wants a system toolchain) do not compile everywhere.
# Extra arguments go to the main cargo test run.

root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/toolchain/lib.sh"
source "$root/toolchain/versions.sh"
source "$root/wasmer/lib.sh"

sc_wasmer_load_variant "${1:?usage: $0 variant [cargo test arguments...]}"
shift

"$root/wasmer/setup.sh" "$WASMER_VARIANT"
sc_wasmer_napi_submodule "$WASMER_VARIANT_TREE"

# The wasix unit-test build embeds fixtures from this submodule.
git -C "$WASMER_VARIANT_TREE" submodule update --init --depth 1 \
  wasmer-test-files >/dev/null 2>&1 ||
  git -C "$WASMER_VARIANT_TREE" submodule update --init wasmer-test-files || {
    echo "could not check out the wasmer-test-files fixture submodule" >&2
    exit 1
  }

# The workspace members in the dependency tree of lib/cli under the features
# wasmer/build.sh builds with, minus wasmer-vm, which runs separately below.
crates=(
  virtual-fs virtual-mio virtual-net
  wasmer wasmer-backend-api wasmer-cli wasmer-compiler
  wasmer-compiler-cranelift wasmer-config
  wasmer-derive wasmer-journal wasmer-package wasmer-sdk wasmer-types
  wasmer-wasix wasmer-wasix-types wasmer-wast
)

run_tests() {
  CARGO_TARGET_DIR="$root/work/build/wasmer/$WASMER_VARIANT" cargo test --locked \
    --lib --manifest-path "$WASMER_VARIANT_TREE/Cargo.toml" "$@"
}

# The wasmer-vm suite asserts on process-global state (the TLS stack pool),
# and the production entry points it goes through cannot take the suite's
# test mutex across a thread join, so those assertions race under parallel
# test threads — on the unpatched tree too. Run that suite single-threaded.
run_tests -p wasmer-vm -- --test-threads=1

packages=()
for crate in "${crates[@]}"; do
  packages+=(-p "$crate")
done
run_tests "${packages[@]}" "$@"
