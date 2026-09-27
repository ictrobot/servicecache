# Included by every project toolchain/guest/toolchain.cmake configures, once
# the compiler modules have set their defaults, which is the earliest a
# project can undo one of them.

# A guest module is linked once and loaded by a runtime that relocates
# nothing, so position-independent code buys a build nothing, and its code
# would work out each address of its data as it runs. The
# POSITION_INDEPENDENT_CODE property stays settable; on this target it adds
# no flag.
set(CMAKE_C_COMPILE_OPTIONS_PIC "")
set(CMAKE_CXX_COMPILE_OPTIONS_PIC "")
set(CMAKE_ASM_COMPILE_OPTIONS_PIC "")
