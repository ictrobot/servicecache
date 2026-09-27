#!/usr/bin/env bash
# Assemble the compiler wrappers, guest.cfg and Clang
# resource directory in SC_OUT_DIR, using inputs from toolchain/default.nix.
set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$SC_OUT_DIR"
mkdir -p "$out/bin" "$out/share" "$out/resource/include"

sed -e "s|@sysroot@|$SC_SYSROOT_DIR|g" \
  -e "s|@resource@|$out/resource|g" \
  -e "s|@linker-dir@|$SC_LLD_DIR/bin|g" \
  "$here/guest.cfg" > "$out/share/guest.cfg"
if grep -q '@[a-z-]*@' "$out/share/guest.cfg"; then
  fail "guest.cfg names a location this script does not fill in: $(grep -o '@[a-z-]*@' "$out/share/guest.cfg" | head -n 1)"
fi

# --no-default-config: no configuration file of the machine's or of the user's
# joins guest.cfg.
for pair in guest-cc:clang guest-c++:clang++; do
  printf '#!%s\nexec %s --no-default-config --config=%s "$@"\n' \
    "$BASH" "$SC_CLANG_DIR/bin/${pair#*:}" "$out/share/guest.cfg" > "$out/bin/${pair%%:*}"
  chmod +x "$out/bin/${pair%%:*}"
done
# llvm-ar and llvm-ranlib are one program, which takes its mode from the name
# it is run by.
ln -s "$SC_LLVM_DIR/bin/llvm-ar" "$out/bin/guest-ar"
ln -s "$SC_LLVM_DIR/bin/llvm-ranlib" "$out/bin/guest-ranlib"
ln -s "$SC_LLVM_DIR/bin/llvm-nm" "$out/bin/guest-nm"

# The compiler looks for its own headers in its resource directory. The
# guest toolchain gives it a private one, holding links to only the headers
# that apply to every target (the C standard headers clang provides, such as
# stddef.h and stdint.h, and the pieces they are built from) and the
# WebAssembly intrinsics header, wasm_simd128.h. nixpkgs' clang is built for
# every target, so its own resource directory also carries the other
# architectures' intrinsics headers, where a check such as
# __has_include(<arm_neon.h>) would find them and take a code path this
# target does not have.
headers="$("$SC_CLANG_DIR/bin/clang" -print-resource-dir)/include"
for pattern in builtins.h endian.h float.h '__float_*.h' inttypes.h iso646.h limits.h \
  mm_malloc.h module.modulemap stdalign.h stdarg.h '__stdarg_*.h' stdatomic.h stdbool.h \
  stdckdint.h stdcountof.h stddef.h '__stddef_*.h' stddefer.h stdint.h stdnoreturn.h \
  tgmath.h unwind.h varargs.h wasm_simd128.h; do
  found=0
  for header in "$headers"/$pattern; do
    [[ -f "$header" ]] || continue
    ln -s "$header" "$out/resource/include/${header##*/}"
    found=1
  done
  [[ $found -eq 1 ]] || fail "the compiler has no header $pattern in $headers"
done
builtins="$("$out/bin/guest-cc" -print-libgcc-file-name)"
if [[ "$builtins" != "$out/resource/"* ]]; then
  fail "the compiler looks for its builtins outside its resource directory: $builtins"
fi
mkdir -p "$(dirname "$builtins")"
ln -s "$SC_SYSROOT_DIR/lib/wasm32-wasip1/libclang_rt.builtins-wasm32.a" "$builtins"

# Compile and link an empty C program and an empty C++ program with the
# assembled wrappers. A broken toolchain then fails this build.
check="$(mktemp -d)"
printf 'int main(void) { return 0; }\n' > "$check/check.c"
cp "$check/check.c" "$check/check.cc"
"$out/bin/guest-cc" "$check/check.c" -o "$check/c.wasm" || fail "guest-cc cannot build a guest"
"$out/bin/guest-c++" "$check/check.cc" -o "$check/cc.wasm" || fail "guest-c++ cannot build a guest"
rm -rf "$check"
