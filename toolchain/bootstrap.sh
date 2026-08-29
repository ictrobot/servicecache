#!/usr/bin/env bash
set -euo pipefail

SC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SC_CHECK=0
SC_ALL=0

fail() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  echo "usage: $0 [--all] [--check]" >&2
  exit 2
}

for argument in "$@"; do
  case "$argument" in
    --all) SC_ALL=1 ;;
    --check) SC_CHECK=1 ;;
    *) usage ;;
  esac
done

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required host command not found: $1"
}

verify_checksum() {
  printf '%s  %s\n' "$2" "$1" | sha256sum --check --status
}

download() {
  local url="$1"
  local file="$2"
  local checksum="$3"
  local partial="${file}.part"

  if [[ -f "$file" ]]; then
    verify_checksum "$file" "$checksum" ||
      fail "cached download has the wrong checksum: $file"
    echo "using cached download: ${file#"$SC_ROOT"/}"
    return
  fi

  echo "downloading: $url"
  curl --fail --location --retry 3 --output "$partial" "$url"
  verify_checksum "$partial" "$checksum" || fail "download checksum failed: $url"
  mv "$partial" "$file"
}

wasixccenv() {
  "$WASIXCC_DIR/wasixccenv" \
    "-sSYSROOT_PREFIX=$WASIXCC_SYSROOT_PREFIX" \
    "-sLLVM_LOCATION=$WASIXCC_LLVM_LOCATION" \
    "-sBINARYEN_LOCATION=$WASIXCC_BINARYEN_LOCATION" \
    "$@"
}

# Each component is checked and installed on its own, so toolchain sets that
# share a component share its install and sets that differ coexist.

wrapper_ready() {
  [[ -x "$WASIXCC_DIR/bin/wasixcc" ]] || return 1
  [[ "$("$WASIXCC_DIR/bin/wasixcc" --version 2>&1)" == *"wasixcc $WASIXCC_VERSION"* ]]
}

install_wrapper() {
  if wrapper_ready; then
    echo "wasixcc $WASIXCC_VERSION is already installed"
    return
  fi
  [[ ! -e "$WASIXCC_DIR" ]] ||
    fail "incomplete wasixcc installation at $WASIXCC_DIR; move it aside and retry"

  local archive="$SC_ROOT/work/downloads/toolchain/wasixcc-${WASIXCC_VERSION}-linux-x86_64.tar.gz"
  local url="https://github.com/wasix-org/wasixcc/releases/download/v${WASIXCC_VERSION}/wasixcc-x86_64-unknown-linux-gnu.tar.gz"
  download "$url" "$archive" "$WASIXCC_SHA256"

  mkdir -p "$WASIXCC_DIR"
  tar -xzf "$archive" -C "$WASIXCC_DIR"
  "$WASIXCC_DIR/wasixccenv" install-executables "$WASIXCC_DIR/bin"
  wrapper_ready || fail "wasixcc verification failed after installation"
}

sysroot_ready() {
  local variant
  for variant in sysroot sysroot-eh sysroot-ehpic sysroot-exnref-eh sysroot-exnref-ehpic; do
    [[ -d "$WASIXCC_SYSROOT_PREFIX/$variant" ]] || return 1
  done
}

install_sysroot() {
  if sysroot_ready; then
    echo "WASIX sysroot $WASIX_SYSROOT_TAG is already installed"
    return
  fi
  [[ ! -e "$WASIXCC_SYSROOT_PREFIX" ]] ||
    fail "incomplete WASIX sysroot at $WASIXCC_SYSROOT_PREFIX; move it aside and retry"
  wasixccenv download-sysroot "$WASIX_SYSROOT_TAG"
  sysroot_ready || fail "WASIX sysroot verification failed after installation"
}

llvm_ready() {
  [[ -x "$WASIXCC_LLVM_LOCATION/bin/clang" ]] || return 1
  [[ "$("$WASIXCC_LLVM_LOCATION/bin/clang" --version 2>&1)" == *"WASIX clang version ${WASIX_LLVM_TAG%.*}"* ]]
}

install_llvm() {
  if llvm_ready; then
    echo "WASIX LLVM $WASIX_LLVM_TAG is already installed"
    return
  fi
  [[ ! -e "$WASIXCC_LLVM_LOCATION" ]] ||
    fail "incomplete WASIX LLVM at $WASIXCC_LLVM_LOCATION; move it aside and retry"
  wasixccenv download-llvm "$WASIX_LLVM_TAG"
  llvm_ready || fail "WASIX LLVM verification failed after installation"
}

binaryen_ready() {
  [[ -x "$WASIXCC_BINARYEN_LOCATION/bin/wasm-opt" ]] || return 1
  [[ "$("$WASIXCC_BINARYEN_LOCATION/bin/wasm-opt" --version 2>&1)" == *"$BINARYEN_TAG"* ]]
}

install_binaryen() {
  if binaryen_ready; then
    echo "binaryen $BINARYEN_TAG is already installed"
    return
  fi
  [[ ! -e "$WASIXCC_BINARYEN_LOCATION" ]] ||
    fail "incomplete binaryen at $WASIXCC_BINARYEN_LOCATION; move it aside and retry"
  wasixccenv download-binaryen "$BINARYEN_TAG"
  binaryen_ready || fail "binaryen verification failed after installation"
}

wasmer_ready() {
  [[ -x "$WASMER_DIR/bin/wasmer" ]] || return 1
  [[ "$("$WASMER_DIR/bin/wasmer" --version 2>&1)" == "wasmer $WASMER_VERSION" ]]
}

install_wasmer() {
  if wasmer_ready; then
    echo "Wasmer $WASMER_VERSION is already installed"
    return
  fi
  [[ ! -e "$WASMER_DIR" ]] ||
    fail "incomplete Wasmer installation at $WASMER_DIR; move it aside and retry"

  local archive="$SC_ROOT/work/downloads/toolchain/wasmer-${WASMER_VERSION}-linux-amd64.tar.gz"
  local url="https://github.com/wasmerio/wasmer/releases/download/v${WASMER_VERSION}/wasmer-linux-amd64.tar.gz"
  download "$url" "$archive" "$WASMER_SHA256"
  mkdir -p "$WASMER_DIR"
  tar -xzf "$archive" -C "$WASMER_DIR"
  wasmer_ready || fail "Wasmer verification failed after installation"
}

run_smoke() {
  local build_dir="$SC_ROOT/work/build/toolchain-smoke"
  local module="$build_dir/wasix_cpp.wasm"
  local output expected
  mkdir -p "$build_dir"

  "$WASIXCC_DIR/bin/wasix++" -O2 -pthread \
    "$SC_ROOT/toolchain/smoke/threads-exceptions.cpp" -o "$module"
  output="$("$WASMER_DIR/bin/wasmer" run "$module")"
  expected=$'WASIX C++ exception works\nWASIX pthread works'
  [[ "$output" == "$expected" ]] || fail "WASIX smoke test returned unexpected output"
  printf '%s\n' "$output"

  # A second module, for the manager's own tests: it reports what it sees
  # of stdin and of the network, so the embedded runtime can be checked
  # without any service.
  "$WASIXCC_DIR/bin/wasixcc" -O2 \
    "$SC_ROOT/toolchain/smoke/stdio-net.c" -o "$build_dir/stdio-net.wasm"
}

install_current_set() {
  install_wrapper
  install_sysroot
  install_llvm
  install_binaryen
  install_wasmer
  if [[ "$SC_CHECK" -eq 1 ]]; then
    run_smoke
  fi
}

load_default_set() {
  source "$SC_ROOT/toolchain/versions.sh"
  source "$SC_ROOT/toolchain/env.sh"
}

load_service_set() {
  local version_file="$1"
  local service_versions="${version_file%/versions/*}/versions.sh"

  unset WASIXCC_VERSION WASIX_SYSROOT_TAG WASIX_LLVM_TAG BINARYEN_TAG WASMER_VERSION
  unset WASIXCC_SHA256 WASMER_SHA256
  source "$version_file"
  if [[ -f "$service_versions" ]]; then
    source "$service_versions"
  fi
  source "$SC_ROOT/toolchain/versions.sh"
  source "$SC_ROOT/toolchain/env.sh"
}

[[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]] ||
  fail "the pinned binary toolchain is supported only on Linux x86_64"
for command_name in curl sha256sum tar; do
  require_command "$command_name"
done

mkdir -p "$SC_ROOT/work/downloads/toolchain"

set_key() {
  printf '%s|%s|%s|%s|%s' "$WASIXCC_VERSION" "$WASIX_SYSROOT_TAG" \
    "$WASIX_LLVM_TAG" "$BINARYEN_TAG" "$WASMER_VERSION"
}

# Sets are identified by their five pins; a set already handled is skipped so
# services that share the default pins do not repeat its checks and smoke test.
declare -A handled_sets=()

(
  load_default_set
  install_current_set
)
handled_sets["$(load_default_set; set_key)"]=default

if [[ "$SC_ALL" -eq 1 ]]; then
  shopt -s nullglob
  version_files=("$SC_ROOT"/services/*/versions/*/version.env)
  for version_file in "${version_files[@]}"; do
    key="$(load_service_set "$version_file"; set_key)"
    label="${version_file#"$SC_ROOT"/services/}"
    label="${label%/version.env}"
    if [[ -n "${handled_sets[$key]:-}" ]]; then
      echo "$label: same toolchain set as ${handled_sets[$key]}"
      continue
    fi
    (
      load_service_set "$version_file"
      install_current_set
    )
    handled_sets["$key"]="$label"
  done
fi

echo "All requested workspace-local tools are ready."
