{ pkgs, sc }:
let
  version = "23.1.0";
  pin = {
    rev = "ea7d852a70e8bdfaf601d6626a760f9771b2c4b4";
    hash = "sha256-/Rg7mjpmnlq2OzXgnzJKslEBmgg4uH2WJsbeQU+ePbk=";
  };
in
sc.mkSource {
  inherit version;
  name = "llvm-project-${version}";
  upstream = sc.fetchSelectedGit {
    url = "https://github.com/llvm/llvm-project.git";
    inherit (pin) rev hash;
    fetchSubmodules = false;
    selection.scope = [
      "cmake"
      "compiler-rt"
      "libc"
      "libcxx"
      "libcxxabi"
      "libunwind"
      "llvm/cmake"
      "runtimes"
    ];
    selection.exclude = [
      {
        paths = [ "libc/" ];
        keep = [
          "libc/.clang-tidy"
          "libc/.gitignore"
          "libc/CMakeLists.txt"
          "libc/LICENSE.TXT"
          "libc/Maintainers.md"
          "libc/README.txt"
          "libc/shared/"
          "libc/hdr/"
          "libc/include/llvm-libc-macros/"
          "libc/include/llvm-libc-types/"
          "libc/src/__support/CPP/"
          "libc/src/__support/FPUtil/"
          "libc/src/__support/macros/"
          "libc/src/__support/big_int.h"
          "libc/src/__support/common.h"
          "libc/src/__support/ctype_utils.h"
          "libc/src/__support/detailed_powers_of_ten.h"
          "libc/src/__support/high_precision_decimal.h"
          "libc/src/__support/libc_assert.h"
          "libc/src/__support/math_extras.h"
          "libc/src/__support/number_pair.h"
          "libc/src/__support/sign.h"
          "libc/src/__support/str_to_float.h"
          "libc/src/__support/str_to_integer.h"
          "libc/src/__support/str_to_num_result.h"
          "libc/src/__support/uint128.h"
          "libc/src/__support/wctype_utils.h"
        ];
        reason = "Unused as WASIX libc supplies the C library. Keep libc's root files and the support headers used by the guest runtimes.";
      }
      {
        paths = [ "libcxx/docs" ];
        reason = "Unused with LLVM_INCLUDE_DOCS=OFF.";
      }
      {
        paths = [
          "libcxx/lib"
          "libcxx/test"
          "libcxxabi/test"
        ];
        reason = "Unused with LLVM_INCLUDE_TESTS=OFF.";
      }
      {
        paths = [ "compiler-rt/test" ];
        reason = "Unused with COMPILER_RT_INCLUDE_TESTS=OFF.";
      }
      {
        paths = [ "compiler-rt/lib/scudo/" ];
        keep = [ "compiler-rt/lib/scudo/standalone/fuzz/" ];
        reason = "Unused with COMPILER_RT_BUILD_SANITIZERS=OFF. CMake adds the retained fuzz/ subdirectory unconditionally.";
      }
      {
        paths = map (name: "compiler-rt/lib/${name}") [
          "asan"
          "tsan"
          "dfsan"
          "msan"
          "hwasan"
          "rtsan"
          "nsan"
          "lsan"
          "ubsan"
        ];
        reason = "Unused with COMPILER_RT_BUILD_SANITIZERS=OFF.";
      }
      {
        paths = [ "compiler-rt/lib/sanitizer_common" ];
        reason = "Unused with COMPILER_RT_BUILD_SANITIZERS, COMPILER_RT_BUILD_XRAY, COMPILER_RT_BUILD_MEMPROF and COMPILER_RT_BUILD_CTX_PROFILE all OFF.";
      }
      {
        paths = [ "compiler-rt/lib/interception" ];
        reason = "Unused with COMPILER_RT_BUILD_SANITIZERS=OFF and COMPILER_RT_BUILD_MEMPROF=OFF.";
      }
      {
        paths = [ "compiler-rt/lib/xray" ];
        reason = "Unused with COMPILER_RT_BUILD_XRAY=OFF.";
      }
      {
        paths = [ "compiler-rt/lib/fuzzer" ];
        reason = "Unused with COMPILER_RT_BUILD_LIBFUZZER=OFF.";
      }
      {
        paths = [ "compiler-rt/lib/orc" ];
        reason = "Unused with COMPILER_RT_BUILD_ORC=OFF.";
      }
      {
        paths = [ "compiler-rt/lib/profile" ];
        reason = "Unused with COMPILER_RT_BUILD_PROFILE=OFF.";
      }
      {
        paths = [ "compiler-rt/lib/memprof" ];
        reason = "Unused with COMPILER_RT_BUILD_MEMPROF=OFF.";
      }
      {
        paths = [ "compiler-rt/lib/gwp_asan" ];
        reason = "Unused with COMPILER_RT_BUILD_GWP_ASAN=OFF.";
      }
    ];
  };
  patches = sc.patchSeries ./patches;
  tarHash = "sha256-5CA38g7eltR9cUNnePCa6Dk9d9c0U9z/gRw1h9qh95o=";
}
