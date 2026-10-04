#!/usr/bin/env bash
# test.sh: run Go's own tests of the packages the wasix series changes, with
# the toolchain built from the release with its tests (default.nix's tests,
# linked at work/build/go-toolchain-tests): the wasip1 packages as guests of
# the Wasmer CLI built from source, in the environment Go guests are built
# in, and the compiler, assembler and linker packages natively. test-skips
# lists the tests left out, each with its reason.
set -euo pipefail

SC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ $# -eq 0 ]] || fail "usage: $0"
fixture="$SC_ROOT/work/build/go-toolchain-tests"
[[ -d "$fixture" ]] || fail "toolchain not built: $fixture (run './x go --test')"
goroot="$(cd "$fixture" && pwd -P)"
wasmer="$SC_ROOT/work/wasmer/fixes/bin"
[[ -x "$wasmer/wasmer" ]] || fail "Wasmer CLI not built: $wasmer/wasmer (run './x wasmer fixes' first)"

guest_packages=(
  context
  internal/poll
  internal/runtime/atomic
  net
  os
  runtime
  sync
  sync/atomic
  syscall
  time
)
native_packages=(
  cmd/asm/...
  cmd/compile/internal/ssa
  cmd/compile/internal/ssagen
  cmd/internal/obj/...
  cmd/link/...
  internal/buildcfg
)

# skip_pattern package: the package's lines of test-skips as a -skip pattern.
skip_pattern() {
  awk -v package="$1" '$1 == package { printf "%s%s", separator, $2; separator = "|" }' \
    "$SC_ROOT/toolchain/go/test-skips"
}

# The go command's caches stay in work/, and nothing of the caller's Go
# configuration applies.
export GOROOT="$goroot" GOCACHE="$SC_ROOT/work/go-test-cache" GOENV=off GOWORK=off
export GOTOOLCHAIN=local GOPROXY=off CGO_ENABLED=0
cd "$goroot/src"

env GOFLAGS= "$goroot/bin/go" test -short "${native_packages[@]}"

# The go command runs a wasip1 test binary through go_wasip1_wasm_exec, which
# starts the Wasmer CLI on PATH with the filesystem mapped. The tests find
# their fixtures through the paths a build records, so this one keeps them.
set -a
# shellcheck source=/dev/null
source "$goroot/servicecache.env"
set +a
export PATH="$goroot/lib/wasm:$wasmer:$PATH"
export GOWASIRUNTIME=wasmer GOWASIRUNTIMEARGS=--net
status=0
for package in "${guest_packages[@]}"; do
  skip="$(skip_pattern "$package")"
  "$goroot/bin/go" test -short -trimpath=false ${skip:+-skip "$skip"} "$package" || status=1
done
exit "$status"
