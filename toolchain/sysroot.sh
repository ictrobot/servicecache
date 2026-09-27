#!/usr/bin/env bash
# sysroot.sh: put the C library toolchain/libc.sh built and what
# toolchain/runtime.sh built in one directory, the sysroot every guest is
# compiled and linked against.
#
#   sysroot.sh LIBC RUNTIME DIRECTORY
#
# DIRECTORY receives both, with the headers in include and the libraries and
# startup files in lib/wasm32-wasip1, which is where clang looks for them for
# the target guests are compiled for (toolchain/guest/guest.cfg). A path both
# hold is refused unless both hold a directory there, where the two are
# merged, so neither replaces a file of the other.
set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}

libc="$1"
runtime="$2"
out="$3"

for part in "$libc" "$runtime"; do
  [[ -d "$part/include" && -d "$part/lib/wasm32-wasip1" ]] ||
    fail "$part has no include and lib/wasm32-wasip1"
done
while IFS= read -r -d '' path; do
  [[ -e "$libc/$path" || -L "$libc/$path" ]] || continue
  [[ -d "$libc/$path" && ! -L "$libc/$path" && -d "$runtime/$path" && ! -L "$runtime/$path" ]] ||
    fail "both $libc and $runtime hold $path"
done < <(cd "$runtime" && find . -print0)

mkdir -p "$out"
cp -R --no-preserve=mode,ownership "$libc/." "$out/"
cp -R --no-preserve=mode,ownership "$runtime/." "$out/"
