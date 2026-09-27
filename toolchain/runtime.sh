#!/usr/bin/env bash
# Build compiler-rt's builtins and the libunwind/libc++abi/libc++ runtime
# against wasix-libc, with WebAssembly exceptions and no PIC. Inputs come
# from toolchain/default.nix; SC_OUT_DIR receives headers and libraries.
set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}

clang="$SC_CLANG_DIR/bin/clang"
export PATH="$SC_CLANG_DIR/bin:$SC_LLD_DIR/bin:$SC_LLVM_DIR/bin:$PATH"

build="$SC_BUILD_DIR"
mkdir -p "$build" "$SC_OUT_DIR"

# run_cmake stage build-directory argument...: one configure, build and
# install, with the output shown only when a step fails.
run_cmake() {
  local stage="$1" directory="$2" step
  shift 2
  for step in configure build install; do
    case "$step" in
      configure) cmake "$@" ;;
      build) cmake --build "$directory" --parallel "$JOBS" ;;
      install) cmake --install "$directory" ;;
    esac > "$directory.$step.log" 2>&1 || {
      tail -n 50 "$directory.$step.log" >&2
      fail "$stage: the $step step failed"
    }
  done
}

# The recipe is wasix-libc's build32-general.sh for its exnref-eh sysroot,
# with these deviations:
#
#   * The target, compilers and flags its CMake toolchain file
#     (tools/clang-wasix-exnref-eh.cmake_toolchain) sets are set here, for
#     wasm32-wasip1, the target guests are compiled for. The file's own
#     triple is wasm32-wasmer-wasi, which this clang calls a deprecated name
#     of the same target and warns about on every compile.
#   * The libraries are installed in lib/wasm32-wasip1, where clang looks for
#     that target's.
#   * Of compiler-rt, only the builtins: guests link nothing else of it.
#   * LIBCXX_HAS_MUSL_LIBC=OFF, as the WASI SDK builds libc++. With it on,
#     libc++ compiles calls to copy_file_range, which the C library does not
#     declare.
#   * CMAKE_POLICY_VERSION_MINIMUM=3.5, because compiler-rt and the runtimes
#     still declare compatibility with CMake 3, which CMake 4 refuses.
#   * LLVM_INCLUDE_TESTS=OFF, because the source carries llvm/cmake alone and
#     the test machinery reaches for the rest of llvm/.
#   * LLVM_INCLUDE_DOCS=OFF, because libcxx/docs is a manual built by a tool
#     no build here runs and the source leaves it out.
#   * --sysroot in the compiler flags rather than CMAKE_SYSROOT, so that the
#     search paths stay the ones the compiler chooses for the target.
#
# Every absolute path that would otherwise reach the archives' debug
# information is mapped to a fixed token, as wasix-libc's build does: the
# source tree, the build directory and the compiler's resource directory.
target=wasm32-wasip1
compile_flags="-O2 -matomics -mbulk-memory -mmutable-globals -pthread -mthread-model posix"
compile_flags+=" -ftls-model=local-exec -fno-trapping-math"
compile_flags+=" -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS"
compile_flags+=" -fwasm-exceptions -mllvm --wasm-enable-eh -mllvm --wasm-enable-sjlj"
compile_flags+=" -mllvm --wasm-use-legacy-eh=false"
link_flags="-lwasi-emulated-mman -lwasi-emulated-process-clocks -lwasi-emulated-getpid"
link_flags+=" -Wl,--shared-memory -Wl,--max-memory=4294967296 -Wl,--import-memory"
link_flags+=" -Wl,--export-dynamic -Wl,--export=__heap_base -Wl,--export=__stack_pointer"
link_flags+=" -Wl,--export=__data_end -Wl,--export=__wasm_init_tls -Wl,--export=__wasm_signal"
link_flags+=" -Wl,--export=__tls_size -Wl,--export=__tls_align -Wl,--export=__tls_base"
link_flags+=" -Wl,-mllvm,--wasm-enable-eh -Wl,-mllvm,--wasm-enable-sjlj"
link_flags+=" -Wl,-mllvm,--wasm-use-legacy-eh=false -Wl,-mllvm,--exception-model=wasm"
cross=(
  -DCMAKE_SYSTEM_NAME=WASI
  -DCMAKE_SYSTEM_VERSION=1
  -DCMAKE_SYSTEM_PROCESSOR=wasm32
  -DCMAKE_C_COMPILER="$clang"
  -DCMAKE_CXX_COMPILER="$SC_CLANG_DIR/bin/clang++"
  -DCMAKE_C_COMPILER_TARGET="$target"
  -DCMAKE_CXX_COMPILER_TARGET="$target"
  -DCMAKE_ASM_COMPILER_TARGET="$target"
  -DCMAKE_LINKER=wasm-ld
  -DCMAKE_AR="$SC_LLVM_DIR/bin/llvm-ar"
  -DCMAKE_EXE_LINKER_FLAGS="$link_flags"
  -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
)
llvm_tree="$SC_SOURCE_LLVM_PROJECT_DIR"
flags="-ffile-prefix-map=$llvm_tree=. -ffile-prefix-map=$build=."
flags+=" -ffile-prefix-map=$("$clang" -print-resource-dir)=/clang"

# Both are compiled against a copy of the C library in the build directory,
# which the builtins then join for the C++ runtime, as the recipe's build
# sysroots have them.
view="$build/sysroot-view"
mkdir -p "$view"
cp -a "$SC_LIBC_DIR/." "$view/"
chmod -R u+w "$view"

run_cmake "compiler-rt's builtins" "$build/compiler-rt" \
  -S "$llvm_tree/compiler-rt" -B "$build/compiler-rt" \
  "${cross[@]}" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_FLAGS="$flags --sysroot=$view $compile_flags" \
  -DCMAKE_CXX_FLAGS="$flags --sysroot=$view $compile_flags" \
  -DCMAKE_ASM_FLAGS="$flags --sysroot=$view" \
  -DCMAKE_INSTALL_PREFIX="$build/compiler-rt-install" \
  -DCMAKE_C_COMPILER_WORKS=ON \
  -DCMAKE_CXX_COMPILER_WORKS=ON \
  -DCMAKE_C_LINKER_DEPFILE_SUPPORTED=OFF \
  -DCMAKE_CXX_LINKER_DEPFILE_SUPPORTED=OFF \
  -DCOMPILER_RT_BAREMETAL_BUILD=ON \
  -DCOMPILER_RT_INCLUDE_TESTS=OFF \
  -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
  -DCOMPILER_RT_OS_DIR="$target" \
  -DCOMPILER_RT_HAS_FPIC_FLAG=OFF \
  -DCOMPILER_RT_BUILTINS_ENABLE_PIC=OFF \
  -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
  -DCOMPILER_RT_BUILD_XRAY=OFF \
  -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
  -DCOMPILER_RT_BUILD_PROFILE=OFF \
  -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF \
  -DCOMPILER_RT_BUILD_MEMPROF=OFF \
  -DCOMPILER_RT_BUILD_ORC=OFF \
  -DCOMPILER_RT_BUILD_GWP_ASAN=OFF \
  -DCOMPILER_RT_USE_LLVM_UNWINDER=OFF \
  -DCOMPILER_RT_ENABLE_STATIC_UNWINDER=OFF \
  -DCOMPILER_RT_HAS_FUNWIND_TABLES_FLAG=OFF \
  -DSANITIZER_USE_STATIC_LLVM_UNWINDER=OFF \
  -DHAVE_UNWIND_H=OFF \
  -DUNIX:BOOL=ON
llvm-ranlib "$build/compiler-rt-install/lib/$target/libclang_rt.builtins-wasm32.a"

cp -a "$build/compiler-rt-install/." "$view/"

run_cmake "the C++ runtime" "$build/runtimes" \
  -S "$llvm_tree/runtimes" -B "$build/runtimes" \
  "${cross[@]}" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_FLAGS="$flags --sysroot=$view $compile_flags" \
  -DCMAKE_CXX_FLAGS="$flags --sysroot=$view $compile_flags" \
  -DCMAKE_ASM_FLAGS="$flags --sysroot=$view" \
  -DCMAKE_INSTALL_PREFIX="$build/runtimes-install" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=OFF \
  -DCMAKE_C_COMPILER_WORKS=ON \
  -DCMAKE_CXX_COMPILER_WORKS=ON \
  -DLLVM_COMPILER_CHECKED=ON \
  -DLLVM_ENABLE_PIC=OFF \
  -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind" \
  -DLLVM_LIBDIR_SUFFIX="/$target" \
  -DLIBCXX_LIBDIR_SUFFIX="/$target" \
  -DLIBCXXABI_LIBDIR_SUFFIX="/$target" \
  -DLIBCXX_ENABLE_THREADS:BOOL=ON \
  -DLIBCXX_HAS_PTHREAD_API:BOOL=ON \
  -DLIBCXX_HAS_EXTERNAL_THREAD_API:BOOL=OFF \
  -DLIBCXX_HAS_WIN32_THREAD_API:BOOL=OFF \
  -DLIBCXX_ENABLE_SHARED:BOOL=OFF \
  -DLIBCXX_ENABLE_EXCEPTIONS:BOOL=ON \
  -DLIBCXX_ENABLE_FILESYSTEM:BOOL=ON \
  -DLIBCXX_CXX_ABI=libcxxabi \
  -DLIBCXX_HAS_MUSL_LIBC:BOOL=OFF \
  -DLIBCXX_ABI_VERSION=2 \
  -DLIBCXX_USE_COMPILER_RT=ON \
  -DLIBCXXABI_ENABLE_EXCEPTIONS:BOOL=ON \
  -DLIBCXXABI_ENABLE_SHARED:BOOL=OFF \
  -DLIBCXXABI_SILENT_TERMINATE:BOOL=ON \
  -DLIBCXXABI_ENABLE_THREADS:BOOL=ON \
  -DLIBCXXABI_HAS_PTHREAD_API:BOOL=ON \
  -DLIBCXXABI_HAS_EXTERNAL_THREAD_API:BOOL=OFF \
  -DLIBCXXABI_HAS_WIN32_THREAD_API:BOOL=OFF \
  -DLIBCXXABI_USE_LLVM_UNWINDER:BOOL=ON \
  -DLIBUNWIND_ENABLE_SHARED:BOOL=OFF \
  -DLIBUNWIND_ENABLE_STATIC:BOOL=ON \
  -DLIBUNWIND_USE_COMPILER_RT:BOOL=ON \
  -DLIBUNWIND_ENABLE_THREADS:BOOL=ON \
  -DLIBUNWIND_HAS_PTHREAD_LIB:BOOL=ON \
  -DLIBUNWIND_INSTALL_LIBRARY:BOOL=ON \
  -DUNIX:BOOL=ON

cp -a "$build/compiler-rt-install/." "$SC_OUT_DIR/"
cp -a "$build/runtimes-install/." "$SC_OUT_DIR/"
echo "built compiler-rt's builtins, libunwind, libc++abi and libc++ for $target"
