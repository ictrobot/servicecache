#!/usr/bin/env bash
# Build wasix-libc with mimalloc, following its build32-general.sh recipe:
# WebAssembly exceptions and no PIC, matching toolchain/guest/guest.cfg.
# toolchain/default.nix supplies inputs; SC_OUT_DIR receives the sysroot files.
set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}

# The makefile runs clang, and the llvm-ar and llvm-nm its name gives.
export PATH="$SC_CLANG_DIR/bin:$SC_LLVM_DIR/bin:$PATH"

# wasix-libc builds inside its own tree, so it is built in a copy. The symbols
# its build can check are dlmalloc's, so that check is off. The makefile
# compiles for wasm32-wasi, a name this clang deprecates for wasm32-wasip1 and
# warns about on every compile, which -Werror makes an error. wasm32-wasip1 is
# the target guests are compiled for, and it also names the directory the
# libraries are installed in, which is where clang looks for that target's.
libc_tree="$SC_BUILD_DIR/wasix-libc"
mkdir -p "$SC_BUILD_DIR"
cp -r "$SC_SOURCE_WASIX_LIBC_DIR" "$libc_tree"
chmod -R u+w "$libc_tree"
(
  cd "$libc_tree"
  TARGET_ARCH=wasm32 TARGET_OS=wasix CC=clang CXX=clang++ \
    make --silent CHECK_SYMBOLS=no MALLOC_IMPL=mimalloc \
    MIMALLOC_DIR="$SC_SOURCE_MIMALLOC_DIR" -j"$JOBS" \
    -f Makefile-eh EXNREF_EH=yes PIC=no TARGET_TRIPLE=wasm32-wasip1
) > "$SC_BUILD_DIR/wasix-libc.log" 2>&1 || {
  tail -n 50 "$SC_BUILD_DIR/wasix-libc.log" >&2
  fail "building wasix-libc failed"
}
# As build32-general.sh does before it assembles a sysroot: the long-double
# printing and scanning archive is built and then dropped.
rm -f "$libc_tree/sysroot/lib/wasm32-wasip1/libc-printscan-long-double.a"
mkdir -p "$SC_OUT_DIR"
cp -a "$libc_tree/sysroot/." "$SC_OUT_DIR/"
echo "built wasix-libc with mimalloc for wasm32-wasip1"
