#!/usr/bin/env bash
set -euo pipefail

SC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SC_CHECK=0
SC_ALL=0

source "$SC_ROOT/toolchain/lib.sh"

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

# The sysroot's libc carries patches/wasix-libc (see its README): wasix-libc
# is checked out at the sysroot's tag under work/wasix-libc, the series is
# applied, and libc is built from it with wasix-libc's own build for every
# sysroot variant wasixcc can target; that libc.a replaces the downloaded
# one. A stamp next to each archive holds the series hash, so a fresh
# download or a changed series is rebuilt. The legacy exception-handling
# variants (sysroot-eh, sysroot-ehpic) cannot be selected through wasixcc
# and are left as downloaded. The make arguments are the ones wasix-libc's
# build32-general.sh uses for each variant.
SYSROOT_PATCH_VARIANTS=(
  "sysroot:-f Makefile PIC=no"
  "sysroot-exnref-eh:-f Makefile-eh EXNREF_EH=yes PIC=no"
  "sysroot-exnref-ehpic:-f Makefile-eh EXNREF_EH=yes PIC=yes"
)

sysroot_patched() {
  local hash entry variant stamp
  hash="$(sc_sysroot_patch_hash)"
  for entry in "${SYSROOT_PATCH_VARIANTS[@]}"; do
    variant="${entry%%:*}"
    stamp="$WASIXCC_SYSROOT_PREFIX/$variant/lib/wasm32-wasi/libc.a.sc-patched"
    [[ -f "$stamp" && "$(cat "$stamp")" == "$hash" ]] || return 1
  done
}

patch_sysroot() {
  if sysroot_patched; then
    echo "WASIX sysroot patches are applied"
    return
  fi

  local checkout="$SC_ROOT/work/wasix-libc"
  (
    sc_checkout https://github.com/wasix-org/wasix-libc.git "$WASIX_SYSROOT_TAG" "$checkout"
    sc_apply_series "$SC_ROOT/patches/wasix-libc" "$checkout"
  ) || fail "could not prepare the wasix-libc checkout"

  local hash entry variant flags lib
  hash="$(sc_sysroot_patch_hash)"
  for entry in "${SYSROOT_PATCH_VARIANTS[@]}"; do
    variant="${entry%%:*}"
    flags="${entry#*:}"
    lib="$WASIXCC_SYSROOT_PREFIX/$variant/lib/wasm32-wasi/libc.a"
    rm -rf "$checkout/sysroot" "$checkout/build"
    # shellcheck disable=SC2086
    (cd "$checkout" && PATH="$WASIXCC_LLVM_LOCATION/bin:$PATH" \
      TARGET_ARCH=wasm32 TARGET_OS=wasix CC=clang CXX=clang++ \
      make --silent CHECK_SYMBOLS=yes -j"$(nproc)" $flags) > "$checkout/build.log" 2>&1 ||
      fail "building wasix-libc for $variant failed; see $checkout/build.log"
    cp "$checkout/sysroot/lib/wasm32-wasi/libc.a" "$lib"
    echo "$hash" > "$lib.sc-patched"
    echo "rebuilt $variant/lib/wasm32-wasi/libc.a from the patched wasix-libc"
  done
  rm -rf "$checkout/sysroot" "$checkout/build"
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

# The release binary needs a newer libstdc++ than some distributions carry:
# it unpacks but cannot start. Only bin/wasmer is used, so building that one
# binary from the pinned tag is a complete substitute.
build_wasmer() {
  # A tree of its own, not work/wasmer: that checkout carries the
  # patches/wasmer series, and this build must stay the stock CLI.
  local tree="$SC_ROOT/work/src/wasmer-cli-$WASMER_VERSION"
  local build_dir="$SC_ROOT/work/build/wasmer-cli/$WASMER_VERSION"

  require_command cargo

  echo "building the Wasmer $WASMER_VERSION CLI from source"
  sc_checkout https://github.com/wasmerio/wasmer.git "v$WASMER_VERSION" "$tree"

  # lib/cli needs the wasmer-napi submodule before cargo can load the
  # workspace manifest; nothing the host embeds does.
  git -C "$tree" submodule update --init --depth 1 lib/napi >/dev/null 2>&1 ||
    git -C "$tree" submodule update --init lib/napi ||
    fail "could not check out the wasmer-napi submodule that lib/cli needs"

  # Upstream's own release feature set on Linux x86_64, minus V8; the
  # default features carry no compiler backend at all.
  CARGO_TARGET_DIR="$build_dir" cargo build --release --locked \
    --manifest-path "$tree/lib/cli/Cargo.toml" --bin wasmer \
    --features cranelift,singlepass,wasmer-artifact-create,static-artifact-create,wasmer-artifact-load,static-artifact-load ||
    fail "could not build the Wasmer CLI from source"

  install -D -m 755 "$build_dir/release/wasmer" "$WASMER_DIR/bin/wasmer"
}

install_wasmer() {
  if wasmer_ready; then
    echo "Wasmer $WASMER_VERSION is already installed"
    return
  fi

  # A binary that does not answer with the pinned version is replaced from
  # source rather than asking for it to be cleared by hand.
  if [[ -x "$WASMER_DIR/bin/wasmer" ]]; then
    wasmer_replace_from_source
    return
  fi

  [[ ! -e "$WASMER_DIR" ]] ||
    fail "incomplete Wasmer installation at $WASMER_DIR; move it aside and retry"

  local archive="$SC_ROOT/work/downloads/toolchain/wasmer-${WASMER_VERSION}-linux-amd64.tar.gz"
  local url="https://github.com/wasmerio/wasmer/releases/download/v${WASMER_VERSION}/wasmer-linux-amd64.tar.gz"
  download "$url" "$archive" "$WASMER_SHA256"
  mkdir -p "$WASMER_DIR"
  tar -xzf "$archive" -C "$WASMER_DIR"
  if wasmer_ready; then
    return
  fi
  wasmer_replace_from_source
}

wasmer_replace_from_source() {
  echo "the installed Wasmer does not report the pinned version:" >&2
  # It usually cannot start at all, so this reports rather than checks.
  { "$WASMER_DIR/bin/wasmer" --version 2>&1 || true; } | sed 's/^/  /' >&2
  build_wasmer
  wasmer_ready ||
    fail "Wasmer verification failed after building the CLI from source"
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
  "$WASIXCC_DIR/bin/wasixcc" -O2 \
    "$SC_ROOT/toolchain/smoke/netprobe.c" -o "$build_dir/netprobe.wasm"

  # The libc patch (patches/wasix-libc): two threads making relative-path
  # syscalls at once must not corrupt each other's paths. Fails on the
  # unpatched libc. Once per patched sysroot variant that runs as a plain
  # module.
  local flags
  for flags in "" "-fno-exceptions"; do
    # shellcheck disable=SC2086
    "$WASIXCC_DIR/bin/wasixcc" -O2 -pthread $flags \
      "$SC_ROOT/toolchain/smoke/relpath-race.c" -o "$build_dir/relpath-race.wasm"
    "$WASMER_DIR/bin/wasmer" run "$build_dir/relpath-race.wasm" > /dev/null ||
      fail "relative-path race smoke test failed (wasixcc ${flags:-default flags})"
  done
  echo "WASIX relative-path race test passed"
}

install_current_set() {
  install_wrapper
  install_sysroot
  install_llvm
  install_binaryen
  patch_sysroot
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
for command_name in curl sha256sum tar git make; do
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
