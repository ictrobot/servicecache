# Cross toolchain for a build begun by sc_build_init (toolchain/guest-lib.sh), which
# has the guest toolchain's programs on PATH and the sysroot guest-cc compiles
# against in SC_SYSROOT_DIR.
set(CMAKE_SYSTEM_NAME WASI)
set(CMAKE_SYSTEM_VERSION 1)
set(CMAKE_SYSTEM_PROCESSOR wasm32)

# guest-cc and guest-c++ link as well as compile, running the linker
# themselves.
set(CMAKE_C_COMPILER guest-cc)
set(CMAKE_CXX_COMPILER guest-c++)
set(CMAKE_AR guest-ar)
set(CMAKE_RANLIB guest-ranlib)
set(CMAKE_NM guest-nm)

set(UNIX 1)
set(WASIX 1)

set(CMAKE_EXECUTABLE_SUFFIX ".wasm")

set(CMAKE_SYSROOT "$ENV{SC_SYSROOT_DIR}")
set(CMAKE_FIND_ROOT_PATH "${CMAKE_SYSROOT}")
set(CMAKE_LIBRARY_PATH "${CMAKE_SYSROOT}/lib/wasm32-wasip1")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)

# Run cross-built code generators with the WASIX runner supplied by Nix.
set(CMAKE_CROSSCOMPILING_EMULATOR wasix-runner)
# What a project picks up after its own project() call, which is where the
# compiler modules have already had their say.
set(CMAKE_PROJECT_INCLUDE "${CMAKE_CURRENT_LIST_DIR}/no-pic.cmake")
